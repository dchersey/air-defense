defmodule LgaPredictor.Approach do
  @moduledoc """
  Infers which runway the airport is landing on, from the traffic itself.

  When the airport swings configuration, arrivals stop crossing the monitored zone and
  the app simply goes quiet — indistinguishable from a broken receiver, a dead feed, or
  a genuinely empty sky. That ambiguity is the thing worth removing: "no flights for
  twelve hours" and "they are landing the other way" look identical from inside the
  zone, because with no traffic in the zone there is nothing to measure.

  An aircraft on final is, by definition, aligned with the runway it is landing on, so
  the median track of descending low traffic near the field names the runway. Crab angle
  offsets it by ~10 degrees in a crosswind, which does not matter: runways are 90 degrees
  apart, leaving 45 degrees of tolerance either side.

  Departures must be excluded or they poison the median — they climb out on roughly the
  reciprocal heading, which would drag the answer toward the runway's opposite end.
  """

  @arrival_radius_nm 6.0
  @arrival_ceiling_ft 3000
  # Descending hard enough to be on approach rather than levelling or departing.
  @arrival_vspeed_fpm -200
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

  @doc "Final-approach tracks of aircraft arriving at `airport` in this snapshot."
  @spec arrival_tracks([map()], {number(), number()}) :: [number()]
  def arrival_tracks(aircraft, airport) when is_list(aircraft) do
    aircraft |> Enum.filter(&arriving?(&1, airport)) |> Enum.map(& &1.track_deg)
  end

  def arrival_tracks(_aircraft, _airport), do: []

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
      is_number(ac.alt_ft) and ac.alt_ft < @arrival_ceiling_ft and
      (ac.vspeed_fpm || 0) < @arrival_vspeed_fpm and
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
