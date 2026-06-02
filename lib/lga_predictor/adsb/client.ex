defmodule LgaPredictor.ADSB.Client do
  @moduledoc """
  Free ADS-B feed client (airplanes.live / adsb.lol — both expose the readsb
  schema). A drop-in alternative to `FR24.Client`: returns the same
  `LgaPredictor.FR24.Aircraft` structs the `Poller` consumes, at zero cost and
  with no API key.

  These feeds query a **point + radius** (a circle), not a bounding box, so we
  circumscribe the monitor box with a circle, fetch, then trim back to the box —
  matching what FR24's `bounds` query would have returned. Live ADS-B carries
  ground speed, altitude, track, type and registration, which is everything the
  predictor needs (and then some).
  """

  alias LgaPredictor.FR24.Aircraft

  @hosts %{
    airplanes_live: "https://api.airplanes.live",
    adsb_lol: "https://api.adsb.lol"
  }

  @type bounds :: {number(), number(), number(), number()}

  @doc """
  Fetch aircraft within `bounds` ({north, south, west, east}). `opts[:provider]`
  is `:airplanes_live` (default) or `:adsb_lol`. Returns `{:ok, [%Aircraft{}]}`.
  """
  @spec positions(bounds(), keyword()) :: {:ok, [Aircraft.t()]} | {:error, term()}
  def positions(bounds, opts \\ []) do
    provider = Keyword.get(opts, :provider, :airplanes_live)
    {clat, clon, radius_nm} = bbox_to_circle(bounds)
    url = "#{Map.fetch!(@hosts, provider)}/v2/point/#{f(clat, 4)}/#{f(clon, 4)}/#{f(radius_nm, 1)}"

    req =
      Req.new(
        url: url,
        headers: [{"Accept", "application/json"}, {"User-Agent", "air-defense/0.1"}],
        receive_timeout: 8000,
        retry: false
      )

    case Req.get(Req.merge(req, Keyword.get(opts, :req, []))) do
      {:ok, %{status: 200, body: body}} -> {:ok, parse(body, bounds)}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end

  @doc "Center + covering radius (nm) for a {north, south, west, east} box."
  @spec bbox_to_circle(bounds()) :: {float(), float(), float()}
  def bbox_to_circle({north, south, west, east}) do
    clat = (north + south) / 2
    clon = (west + east) / 2
    radius_m = haversine_m(clat, clon, north, east)
    {clat, clon, min(250.0, max(1.0, radius_m / 1852.0 * 1.15))}
  end

  @doc "Parse a readsb `%{\"ac\" => [...]}` body into Aircraft, trimmed to `bounds`."
  @spec parse(map(), bounds()) :: [Aircraft.t()]
  def parse(%{"ac" => records}, bounds) when is_list(records) do
    records
    |> Enum.filter(&in_box?(&1, bounds))
    |> Enum.map(&to_aircraft/1)
  end

  def parse(_, _), do: []

  defp in_box?(%{"lat" => lat, "lon" => lon}, {north, south, west, east})
       when is_number(lat) and is_number(lon) do
    south <= lat and lat <= north and west <= lon and lon <= east
  end

  defp in_box?(_, _), do: false

  defp to_aircraft(a) do
    %Aircraft{
      hex: a["hex"],
      callsign: trimmed(a["flight"]),
      lat: a["lat"],
      lon: a["lon"],
      track_deg: numeric(a["track"]),
      alt_ft: altitude(a["alt_baro"]),
      gspeed_kt: numeric(a["gs"]),
      vspeed_fpm: numeric(a["baro_rate"]) || 0,
      type: a["t"],
      reg: a["r"]
    }
  end

  defp altitude("ground"), do: 0
  defp altitude(v) when is_number(v), do: v
  defp altitude(_), do: nil

  defp numeric(v) when is_number(v), do: v
  defp numeric(_), do: nil

  defp trimmed(s) when is_binary(s), do: String.trim(s)
  defp trimmed(_), do: nil

  defp f(x, decimals), do: :erlang.float_to_binary(x / 1.0, decimals: decimals)

  defp haversine_m(lat1, lon1, lat2, lon2) do
    r = 6_371_000.0
    dlat = deg2rad(lat2 - lat1)
    dlon = deg2rad(lon2 - lon1)

    a =
      :math.sin(dlat / 2) ** 2 +
        :math.cos(deg2rad(lat1)) * :math.cos(deg2rad(lat2)) * :math.sin(dlon / 2) ** 2

    2 * r * :math.asin(min(1.0, :math.sqrt(a)))
  end

  defp deg2rad(d), do: d * :math.pi() / 180.0
end
