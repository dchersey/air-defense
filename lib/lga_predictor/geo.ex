defmodule LgaPredictor.Geo do
  @moduledoc """
  Pure geospatial helpers for the overflight predictor: great-circle distance,
  dead-reckoning projection, and zone containment. No process state, no I/O.
  """

  @typedoc "A geographic point as `{latitude_deg, longitude_deg}`."
  @type point :: {number(), number()}

  @doc """
  Great-circle distance between two points in kilometres (spherical earth, R=6371 km).
  """
  @spec haversine_km(point(), point()) :: float()
  def haversine_km({lat1, lon1}, {lat2, lon2}) do
    earth_radius_km = 6371.0

    dlat = deg_to_rad(lat2 - lat1)
    dlon = deg_to_rad(lon2 - lon1)
    rlat1 = deg_to_rad(lat1)
    rlat2 = deg_to_rad(lat2)

    a =
      :math.sin(dlat / 2) * :math.sin(dlat / 2) +
        :math.cos(rlat1) * :math.cos(rlat2) * :math.sin(dlon / 2) * :math.sin(dlon / 2)

    c = 2 * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
    earth_radius_km * c
  end

  # Degrees of latitude covered per (knot * second) of ground travel.
  # 1 kt = 1 nm/hr; 1 nm = 1/60 deg latitude; 1 hr = 3600 s  ->  deg = gs_kt * t_s / (60 * 3600).
  # NOTE: the original spec used 222640 here, which is ~3% wrong; 216000 is physically correct.
  @deg_per_kt_second 216_000.0

  @doc """
  Dead-reckoning projection `t` seconds ahead.

  Takes a kinematic state map (`:lat`, `:lon`, `:track_deg`, `:gspeed_kt`,
  `:vspeed_fpm`, `:alt_ft`) and returns `%{lat:, lon:, alt_ft:}` projected forward.
  `track_deg` is course over ground (FR24 `track`), measured clockwise from true north.

  `:accel_kt_s` (default 0) is along-track acceleration in knots/second — for
  departing aircraft that speed up along the arc. Ground distance covered is the
  integral of `gs0 + accel·t`, i.e. `gs0·t + ½·accel·t²` (in kt·s units).
  """
  @spec project(map(), number(), keyword()) :: %{lat: float(), lon: float(), alt_ft: float()}
  def project(%{lat: lat, lon: lon, track_deg: track, gspeed_kt: gs, vspeed_fpm: vs, alt_ft: alt}, t_seconds, opts \\ []) do
    accel = Keyword.get(opts, :accel_kt_s, 0.0)
    track_rad = deg_to_rad(track)

    # ∫(gs + accel·τ) dτ from 0..t, in knot·seconds.
    distance_kt_s = gs * t_seconds + 0.5 * accel * t_seconds * t_seconds

    dlat = distance_kt_s * :math.cos(track_rad) / @deg_per_kt_second
    dlon = distance_kt_s * :math.sin(track_rad) / (@deg_per_kt_second * :math.cos(deg_to_rad(lat)))

    %{
      lat: lat + dlat,
      lon: lon + dlon,
      alt_ft: alt + vs * t_seconds / 60.0
    }
  end

  @typedoc """
  A containment zone: a circle (centre + radius in km) or a polygon (list of
  `{lat, lon}` vertices, implicitly closed).
  """
  @type zone :: {:circle, point(), number()} | {:polygon, [point()]}

  @doc """
  Whether `point` lies within `zone`. Circles use great-circle distance;
  polygons use even-odd ray casting on the lat/lon plane (fine at city scale).
  """
  @spec point_in_zone?(point(), zone()) :: boolean()
  def point_in_zone?(point, {:circle, center, radius_km}) do
    haversine_km(point, center) <= radius_km
  end

  def point_in_zone?({lat, lon}, {:polygon, vertices}) do
    vertices
    |> Enum.zip(rotate(vertices))
    |> Enum.reduce(false, fn {{lat_i, lon_i}, {lat_j, lon_j}}, inside ->
      crosses? =
        lon_i > lon != (lon_j > lon) and
          lat < (lat_j - lat_i) * (lon - lon_i) / (lon_j - lon_i) + lat_i

      if crosses?, do: not inside, else: inside
    end)
  end

  # Kilometres per degree of latitude (great-circle, R=6371 km) — also the
  # north/south scale for the local equirectangular projection below.
  @km_per_deg 6371.0 * :math.pi() / 180.0

  @doc """
  Shortest distance in kilometres from `point` to the boundary of `zone`,
  or `0.0` if the point is inside it. Distance is the minimum point-to-segment
  distance over the polygon edges, computed in a local equirectangular frame
  about the point's latitude (planar approximation, fine at city scale).
  """
  @spec distance_to_zone(point(), zone()) :: float()
  def distance_to_zone(point, {:polygon, vertices} = zone) do
    if point_in_zone?(point, zone) do
      0.0
    else
      vertices
      |> Enum.zip(rotate(vertices))
      |> Enum.map(fn {a, b} -> point_to_segment_km(point, a, b) end)
      |> Enum.min()
    end
  end

  @doc """
  The `{near, far}` distances in kilometres from `point` to a polygon zone:
  `near` is `distance_to_zone/2` (the nearest boundary, 0 if inside) and `far`
  is the great-circle distance to the farthest vertex. Used to estimate how long
  a straight pass through the zone takes (`(far - near) / groundspeed`).
  """
  @spec zone_distance_range(point(), zone()) :: {float(), float()}
  def zone_distance_range(point, {:polygon, vertices} = zone) do
    near = distance_to_zone(point, zone)
    far = vertices |> Enum.map(&haversine_km(point, &1)) |> Enum.max()
    {near, far}
  end

  # Distance from `point` to segment A–B, in km, via a local equirectangular
  # projection centred on the point's latitude (origin = the point itself).
  defp point_to_segment_km({plat, plon}, {alat, alon}, {blat, blon}) do
    kx = @km_per_deg * :math.cos(deg_to_rad(plat))
    ax = (alon - plon) * kx
    ay = (alat - plat) * @km_per_deg
    bx = (blon - plon) * kx
    by = (blat - plat) * @km_per_deg

    dx = bx - ax
    dy = by - ay
    seg_len_sq = dx * dx + dy * dy

    t =
      if seg_len_sq == 0.0,
        do: 0.0,
        else: max(0.0, min(1.0, -(ax * dx + ay * dy) / seg_len_sq))

    cx = ax + t * dx
    cy = ay + t * dy
    :math.sqrt(cx * cx + cy * cy)
  end

  @doc """
  Convert a GeoJSON Polygon `coordinates` value into a `{:polygon, [{lat, lon}]}`
  zone. GeoJSON points are `[lon, lat]` and the first ring is the outer boundary;
  the closing duplicate vertex (first == last) is dropped.
  """
  @spec geojson_polygon([[[number()]]]) :: zone()
  def geojson_polygon([outer_ring | _holes]) do
    points = Enum.map(outer_ring, fn [lon, lat] -> {lat, lon} end)

    points =
      case points do
        [first | _] -> if List.last(points) == first, do: Enum.drop(points, -1), else: points
        [] -> []
      end

    {:polygon, points}
  end

  @doc "Bounding box `{north, south, west, east}` of a polygon zone."
  @spec bbox(zone()) :: {number(), number(), number(), number()}
  def bbox({:polygon, points}) do
    lats = Enum.map(points, &elem(&1, 0))
    lons = Enum.map(points, &elem(&1, 1))
    {Enum.max(lats), Enum.min(lats), Enum.min(lons), Enum.max(lons)}
  end

  defp rotate([head | tail]), do: tail ++ [head]

  defp deg_to_rad(deg), do: deg * :math.pi() / 180.0
end
