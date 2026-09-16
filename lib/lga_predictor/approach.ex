defmodule LgaPredictor.Approach do
  @moduledoc """
  Infers which arrival path the airport is using, from the traffic itself.

  When the airport swings configuration, arrivals stop crossing the monitored zone and
  the app simply goes quiet — indistinguishable from a broken receiver, a dead feed, or
  a genuinely empty sky. That ambiguity is the thing worth removing: "no flights for
  twelve hours" and "they are arriving a different way" look identical from inside the
  zone, because with no traffic in the zone there is nothing to measure.

  The question that matters to a listener under the path is NOT which runway is in use.
  The same runway is fed by routes that differ enormously underfoot: a river approach
  that never crosses the neighbourhood is silent here, while a loop over it at 1500 ft
  with the gear down is the whole reason this app exists. So the runway is inferred as
  supporting detail only, and the reported state is the path, measured where it is
  actually felt — overhead, by altitude band:

    `:low_final`      overhead on final, gear down. The loud one.
    `:high_downwind`  overhead on the longer loop, gear still up. Audible only with
                      the windows open.
    `:not_overhead`   the field is demonstrably landing, and none of it comes over
                      the zone. Quiet — and the reason the flight list is empty.

  `:not_overhead` is only meaningful against evidence that the airport is busy, which is
  why arrivals near the field are counted at all: with no traffic anywhere, an empty zone
  says nothing. Both halves come from one fetch of the airspace around the field, so the
  classification costs nothing beyond what the runway inference already spends.
  """

  # --- Overhead altitude bands ------------------------------------------------------
  # Defined once here because two things depend on them agreeing: this classifier, and
  # the menu-bar icon that goes amber for overhead noise. Measured over the zone.
  #
  #   < 1000 ft   rotorcraft and light GA — every sub-1000ft crossing measured over the
  #               zone was a Bell 206/429 or a Cessna Caravan. Never an airport arrival.
  #   1000-3000   near-arrivals on final, GEAR DOWN. Flights that actually engaged ANC
  #               crossed at 1475-1800 ft.
  #   3000-6000   the longer loop overhead, inbound from the north-east, gear still up.
  #   > 6000      overflying traffic, not bound for this field at all.
  @rotor_ceiling_ft 1000
  @final_ceiling_ft 3000
  @arrival_ceiling_ft 6000

  @doc "Which overhead altitude band `alt` falls in, or nil when the altitude is unknown."
  @spec overhead_band(number() | nil) :: :rotor | :low_final | :high_downwind | :transit | nil
  def overhead_band(alt) when is_number(alt) do
    cond do
      alt < @rotor_ceiling_ft -> :rotor
      alt < @final_ceiling_ft -> :low_final
      alt < @arrival_ceiling_ft -> :high_downwind
      true -> :transit
    end
  end

  def overhead_band(_alt), do: nil

  # Descending hard enough to be arriving rather than levelling off or departing.
  @descent_fpm -200

  # --- Is the field landing? ---------------------------------------------------------
  # A deliberately wider gate than the runway one below, because it answers a different
  # question — and measurement showed the narrow gate cannot answer it. Over 16 minutes
  # of live LGA traffic the final-approach filter matched ZERO aircraft while this one
  # accumulated 12: aircraft on short final are inside 6 nm for barely a minute, and
  # many stop reporting a vertical rate altogether by then. The descent into the
  # terminal area is observed far more reliably than the final itself.
  #
  # This counts DESCENDING traffic in the area, not strictly arrivals at this field — in
  # dense airspace some of it is bound elsewhere. That is the right scope for the
  # question actually being asked: is the sky busy enough that an empty zone means
  # something?
  @field_radius_nm 10.0
  @field_ceiling_ft 6000

  @doc "Descending traffic near `airport` — evidence the field is working."
  @spec landing_traffic([map()], {number(), number()}) :: [map()]
  def landing_traffic(aircraft, airport) when is_list(aircraft),
    do: Enum.filter(aircraft, &descending_near?(&1, airport))

  def landing_traffic(_aircraft, _airport), do: []

  defp descending_near?(ac, {alat, alon}) do
    is_number(ac.lat) and is_number(ac.lon) and is_number(ac.alt_ft) and
      ac.alt_ft < @field_ceiling_ft and (ac.vspeed_fpm || 0) < @descent_fpm and
      distance_nm(ac.lat, ac.lon, alat, alon) <= @field_radius_nm
  end

  # Below this much traffic, an empty zone is not evidence of anything — it is just a
  # quiet sky. A busy evening measured 12 in 15 minutes, so 4 clears easily in normal
  # operation while still staying silent overnight.
  @min_arrivals 4
  # One crossing is a stray (a go-around, a single odd vector). Two is a pattern.
  @min_overhead 2

  @doc """
  The arrival path in use, from `traffic` (distinct descending aircraft near the field,
  per `landing_traffic/2`) and `overhead` (altitudes of distinct aircraft that crossed
  the zone), both over the same recent window.

  Returns nil rather than guessing: too little traffic to interpret an empty zone, too
  few crossings to call a band, or a genuinely mixed picture.
  """
  @spec overhead_path(non_neg_integer(), [number() | nil]) ::
          :low_final | :high_downwind | :not_overhead | nil
  def overhead_path(traffic, overhead) when is_integer(traffic) and is_list(overhead) do
    seen = Enum.map(overhead, &overhead_band/1)
    bands = Enum.filter(seen, &(&1 in [:low_final, :high_downwind]))

    cond do
      traffic < @min_arrivals ->
        nil

      # Nothing crossed at an arrival altitude — but only call that "not overhead" if
      # every crossing was actually READ. An aircraft whose altitude the feed omitted
      # crossed the zone; reporting the route as avoiding us would be a claim the data
      # does not support.
      bands == [] and not Enum.member?(seen, nil) ->
        :not_overhead

      length(bands) < @min_overhead ->
        nil

      true ->
        dominant_band(bands)
    end
  end

  # A clear two-thirds majority, or nothing. Without this, traffic split across both
  # bands would flip the reported path on every poll and fill the timeline with noise
  # about noise. An unclear picture is reported as unclear (nil = leave the state alone).
  defp dominant_band(bands) do
    n = length(bands)
    low = Enum.count(bands, &(&1 == :low_final))

    cond do
      low * 3 >= n * 2 -> :low_final
      (n - low) * 3 >= n * 2 -> :high_downwind
      true -> nil
    end
  end

  # --- Runway inference (supporting detail) ------------------------------------------
  # An aircraft on final is by definition aligned with the runway it is landing on, so
  # the median track of descending low traffic near the field names the runway. Crab
  # angle offsets it by ~10 degrees in a crosswind, which does not matter: runways are
  # 90 degrees apart. Departures must be excluded or they poison the median — they climb
  # out on roughly the reciprocal heading, dragging the answer to the runway's other end.

  @arrival_radius_nm 6.0
  @approach_ceiling_ft 3000
  # Below this many samples the median is not worth trusting. Samples are ACCUMULATED
  # across polls rather than taken from one frame: LGA rarely has two arrivals inside
  # 6 nm simultaneously, so a single snapshot almost always sees one or none. The runway
  # does not change minute to minute, so pooling recent observations is both more
  # available and more robust — it also averages out go-arounds and strays.
  @min_samples 3
  # A track further than this from every configured runway is not a final approach —
  # say nothing rather than guess. Must be well under half the runway spacing or it can
  # never reject anything: with runways 90 degrees apart, EVERY possible track is within
  # 45 degrees of one of them. Real finals sit within ~15 degrees even in a stiff
  # crosswind, so 25 leaves room for crab while still rejecting transiting traffic.
  @max_offset_deg 25

  @type runway :: %{name: String.t(), heading: number()}

  @doc """
  The runway `aircraft` are landing on, as `{name, median_track, sample_count}`, or nil
  when there is not enough descending traffic near the field to tell.
  """
  @spec active_runway([map()], {number(), number()}, [runway()]) ::
          {String.t(), number(), non_neg_integer()} | nil
  def active_runway(aircraft, airport, runways) do
    aircraft |> arrival_tracks(airport) |> runway_from_tracks(runways)
  end

  @doc "Aircraft in this snapshot that are on final approach to `airport`."
  @spec arrivals([map()], {number(), number()}) :: [map()]
  def arrivals(aircraft, airport) when is_list(aircraft),
    do: Enum.filter(aircraft, &arriving?(&1, airport))

  def arrivals(_aircraft, _airport), do: []

  @doc "Final-approach tracks of aircraft arriving at `airport` in this snapshot."
  @spec arrival_tracks([map()], {number(), number()}) :: [number()]
  def arrival_tracks(aircraft, airport),
    do: aircraft |> arrivals(airport) |> Enum.map(& &1.track_deg)

  @doc """
  The runway a pool of observed final-approach tracks implies, or nil when there are too
  few or they match no runway closely enough.
  """
  @spec runway_from_tracks([number()], [runway()]) ::
          {String.t(), number(), non_neg_integer()} | nil
  def runway_from_tracks(tracks, runways)
      when is_list(tracks) and is_list(runways) and runways != [] do
    with true <- length(tracks) >= @min_samples,
         median when is_number(median) <- circular_median(tracks),
         {name, offset} <- nearest_runway(median, runways),
         true <- offset <= @max_offset_deg do
      {name, median, length(tracks)}
    else
      _ -> nil
    end
  end

  def runway_from_tracks(_tracks, _runways), do: nil

  defp arriving?(ac, {alat, alon}) do
    is_number(ac.lat) and is_number(ac.lon) and is_number(ac.track_deg) and
      is_number(ac.alt_ft) and ac.alt_ft < @approach_ceiling_ft and
      (ac.vspeed_fpm || 0) < @descent_fpm and
      distance_nm(ac.lat, ac.lon, alat, alon) <= @arrival_radius_nm
  end

  defp distance_nm(lat1, lon1, lat2, lon2) do
    dlat = (lat2 - lat1) * 60.0
    dlon = (lon2 - lon1) * 60.0 * :math.cos(rad(lat1))
    :math.sqrt(dlat * dlat + dlon * dlon)
  end

  # Headings wrap, so a plain median is wrong across 360/0 — tracks of 350 and 10 average
  # to 180 (due south) rather than 0 (due north). Average the unit vectors instead.
  defp circular_median(tracks) do
    {sx, sy} =
      Enum.reduce(tracks, {0.0, 0.0}, fn t, {x, y} ->
        {x + :math.cos(rad(t)), y + :math.sin(rad(t))}
      end)

    :math.atan2(sy / length(tracks), sx / length(tracks)) |> deg() |> normalise()
  end

  defp nearest_runway(track, runways) do
    runways
    |> Enum.map(fn r -> {r.name, angular_distance(track, r.heading)} end)
    |> Enum.min_by(&elem(&1, 1))
  end

  @doc false
  def angular_distance(a, b) do
    d = abs(normalise(a) - normalise(b))
    min(d, 360.0 - d)
  end

  defp normalise(deg), do: :math.fmod(:math.fmod(deg, 360.0) + 360.0, 360.0)
  defp rad(d), do: d * :math.pi() / 180.0
  defp deg(r), do: r * 180.0 / :math.pi()
end
