defmodule LgaPredictor.Approach do
  @moduledoc """
  Infers which arrival route the airport is using, from the traffic itself.

  When the airport swings configuration, arrivals stop crossing the monitored zone and
  the app simply goes quiet — indistinguishable from a broken receiver, a dead feed, or
  a genuinely empty sky. That ambiguity is the thing worth removing: "no flights for
  twelve hours" and "they are arriving a different way" look identical from inside the
  zone, because with no traffic in the zone there is nothing to measure.

  The question that matters to a listener under the path is NOT which runway is in use.
  The same runway is fed by routes that differ enormously underfoot: a river approach
  that never crosses the neighbourhood is silent here, while a loop over it at 1500 ft
  with the gear down is the whole reason this app exists. So the runway is inferred as
  supporting detail only, and the reported state is the route, measured by the one
  number a listener cares about — how close each arrival came to home, and how high it
  was when it did:

    `:low_approach`   arrivals pass within `@near_home_nm` at 1000-3000 ft, gear down.
                      The loud one; the same band that lights the icon amber.
    `:high_approach`  arrivals pass within `@near_home_nm` at 3000-6000 ft — the long
                      loop out to the north-east before turning back in, gear still up,
                      a steady ~3600 ft. Audible only with the windows open.
    `:river_approach` the field is landing and none of it comes near. Quiet — and the
                      reason the flight list is empty. The label is the listener's name
                      for it; strictly it means "whatever they are flying avoids you".

  A local receiver sees the entire arrival stream, so the stream is what gets measured:
  every aircraft in the terminal area is followed, and only those that demonstrably LAND
  at this field get a vote. The route reported is the noisiest one in meaningful use —
  not a majority. During a high-approach period only some arrivals fly the loop while the
  rest come straight in from the other side; a majority would have called that "river"
  while seven aircraft in thirteen minutes went over the listener at 3600 ft.
  """

  # --- Overhead altitude bands ------------------------------------------------------
  # Defined once here because two things depend on them agreeing: this classifier, and
  # the menu-bar icon that goes amber for overhead noise. Measured over the zone.
  #
  #   < 1000 ft   rotorcraft and light GA — every sub-1000ft crossing measured over the
  #               zone was a Bell 206/429 or a Cessna Caravan. Never an airport arrival.
  #   1000-3000   LOW APPROACH — near-arrivals on final, GEAR DOWN. Flights that
  #               actually engaged ANC crossed at 1475-1800 ft. The loud one.
  #   3000-6000   HIGH APPROACH — the long loop that runs out over the borough to the
  #               north-east before turning back in. Gear still up; observed at a
  #               steady 3575-3600 ft. Audible only with the windows open.
  #   > 6000      overflying traffic, not bound for this field at all.
  @rotor_ceiling_ft 1000
  @final_ceiling_ft 3000
  @arrival_ceiling_ft 6000

  @doc "Which overhead altitude band `alt` falls in, or nil when the altitude is unknown."
  @spec overhead_band(number() | nil) :: :rotor | :low_approach | :high_approach | :transit | nil
  def overhead_band(alt) when is_number(alt) do
    cond do
      alt < @rotor_ceiling_ft -> :rotor
      alt < @final_ceiling_ft -> :low_approach
      alt < @arrival_ceiling_ft -> :high_approach
      true -> :transit
    end
  end

  def overhead_band(_alt), do: nil

  # Descending hard enough to be arriving rather than levelling off or departing.
  @descent_fpm -200

  # --- Which route are the arrivals flying? ------------------------------------------
  # An earlier design inferred the route from crossings of the ANC zone, and it broke the
  # first time the high approach threaded past the polygon instead of through it — same
  # routing, same 3600 ft, a mile or two of lateral drift, and the zone saw nothing. That
  # polygon was drawn to decide when to ENGAGE ANC, which is a different question.

  # Follow anything this close to the field and this low. Departures climb out through
  # the same airspace and are dropped by their climb rate; the high approach's outbound
  # leg is level (±64 fpm measured), so it stays.
  @terminal_radius_nm 15.0
  @terminal_ceiling_ft 6000
  @climbing_fpm 500

  # A position older than this is not where the aircraft is. Measured: readsb re-emitted
  # a frozen lat/lon for 60+ s after losing an aircraft at 3 nm, with the altitude still
  # updating — a low, "descending", stationary target that the gates below would
  # otherwise take for a landing.
  @max_pos_age_s 15

  # "Bound for THIS field", which is the vote gate. NOT "landed": this antenna never sees
  # a landing. Measured over a twelve-minute bank, six airliners were tracked on the
  # loop's outbound leg and every one lost position at 2575-3100 ft, 2-4 nm from the
  # field; not one final was received afterwards, at any altitude, from any direction.
  # The runway-22 approach comes in over the far side, low, 7-10 nm from the antenna,
  # and simply never reaches it. A gate that waits for the last mile waits forever
  # (it confirmed one landing in thirty-four).
  #
  # Two things ARE observable and are unambiguously this field's traffic:
  #   (a) anything under the ceiling inside the terminal core — nothing else flies that
  #       low that close, in any direction, at any speed. The loop leg lives here.
  #   (b) a descent outside the core that is closing on the field. A neighbouring
  #       airport's arrivals descend through this box too, but heading away.
  @core_radius_nm 4.0
  @core_ceiling_ft 3500
  @closing_radius_nm 10.0
  @closing_ceiling_ft 6000
  @closing_max_offset_deg 60

  # How close an arrival must come to count as "over you". Measured against a live high
  # approach at the 60-second ambient cadence: seven aircraft came within 1.0-2.0 nm of
  # home, and NOTHING else came within 4.8 (the nearest being GA, then this field's own
  # straight-in finals at 6.4+). 3.0 sits in that gap with a mile of margin each way, and
  # is wider than the ANC zone on purpose — the zone is where ANC engages, not where an
  # arrival stops being over you.
  @near_home_nm 3.0

  # Fewer arrivals than this on a route and it is not in meaningful use: a lull, or a
  # stray, not a route.
  @min_landings 3
  # Near-home passes the river call tolerates. One is a go-around or an odd vector; two
  # means the loop is being flown.
  @river_max_strays 1
  # A landing stops describing the current routing after this long.
  @retention_seconds 1200

  # A vote is cast only once the pass is COMPLETE: the aircraft is now moving away from
  # home, or it has dropped off the receiver. Without this an inbound aircraft votes the
  # moment it is recognised as bound — twelve miles out, "never came near" — and three
  # arriving together announce the river three minutes before they cross home at
  # 3600 ft. Measured live: that was the installed app's first marker.
  @passed_margin_nm 0.5
  @gone_seconds 120

  @typedoc "What is remembered per aircraft: its closest pass to home, and whether it is this field's traffic."
  @type pass :: %{
          closest_nm: number() | nil,
          closest_alt: number() | nil,
          last_nm: number() | nil,
          bound: boolean(),
          last_seen: integer()
        }

  @doc "How long a landing keeps voting on the route."
  @spec retention_seconds() :: pos_integer()
  def retention_seconds, do: @retention_seconds

  @doc """
  Fold this poll's sightings into the per-aircraft `passes` map: update each aircraft's
  closest approach to `home` and mark it bound for `airport` once it is seen in the
  terminal core or closing on the field. Aircraft not seen for `@retention_seconds`
  are dropped.
  """
  @spec track_passes(%{String.t() => pass()}, [map()], {number(), number()}, {number(), number()}, integer()) ::
          %{String.t() => pass()}
  def track_passes(passes, aircraft, airport, {hlat, hlon} = _home, now)
      when is_map(passes) and is_list(aircraft) do
    aircraft
    |> Enum.filter(&terminal?(&1, airport))
    |> Enum.reduce(passes, fn ac, acc ->
      case ac.hex || ac.callsign do
        nil ->
          acc

        key ->
          d = distance_nm(ac.lat, ac.lon, hlat, hlon)
          prior =
            Map.get(acc, key, %{closest_nm: nil, closest_alt: nil, last_nm: nil, bound: false, last_seen: now})

          nearer? = is_nil(prior.closest_nm) or d < prior.closest_nm

          Map.put(acc, key, %{
            closest_nm: if(nearer?, do: d, else: prior.closest_nm),
            closest_alt: if(nearer?, do: ac.alt_ft, else: prior.closest_alt),
            last_nm: d,
            bound: prior.bound or bound_here?(ac, airport),
            last_seen: now
          })
      end
    end)
    |> Map.filter(fn {_k, p} -> p.last_seen > now - @retention_seconds end)
  end

  @doc """
  The route in use, from the aircraft bound for this field whose pass is complete: the
  noisiest routing with at least `@min_landings` recent arrivals on it, or nil when too
  few to say.
  """
  @spec route(%{String.t() => pass()}, integer()) :: :low_approach | :high_approach | :river_approach | nil
  def route(passes, now) when is_map(passes) and is_integer(now) do
    votes =
      for {_k, %{bound: true} = p} <- passes, passed?(p, now), v = vote(p), v != nil, do: v
    low = Enum.count(votes, &(&1 == :low_approach))
    high = Enum.count(votes, &(&1 == :high_approach))
    river = Enum.count(votes, &(&1 == :river_approach))

    # Every route earns its own threshold. River was once the fallback whenever neither
    # noisy route reached three votes, which made it the DEFAULT at low traffic: two
    # airliners crossing home at 3600 ft plus one GA aircraft that did not came out as
    # "they avoid you". River means the arrivals are landing and staying away — three of
    # them, with at most one stray near-home pass. Two near-home passes alongside three
    # river ones is a changeover in progress, and the honest answer is not yet.
    cond do
      low >= @min_landings -> :low_approach
      high >= @min_landings -> :high_approach
      river >= @min_landings and low + high <= @river_max_strays -> :river_approach
      true -> nil
    end
  end

  # Moving away from home again, or not seen for a while (this antenna loses every
  # arrival before it lands, so "gone" is how a completed pass usually looks).
  defp passed?(%{closest_nm: c, last_nm: l}, _now) when is_number(c) and is_number(l) and l > c + @passed_margin_nm,
    do: true

  defp passed?(%{last_seen: seen}, now), do: now - seen > @gone_seconds

  # A field-bound aircraft that never came near is a vote for "they avoid you". One that did
  # votes by the band it was in at its closest — unless that band says nothing about an
  # arrival (rotorcraft floor, or an altitude the feed omitted), in which case it abstains
  # rather than being counted as evidence of the quiet routing.
  defp vote(%{closest_nm: d}) when is_nil(d), do: nil
  defp vote(%{closest_nm: d}) when d > @near_home_nm, do: :river_approach

  defp vote(%{closest_alt: alt}) do
    case overhead_band(alt) do
      band when band in [:low_approach, :high_approach] -> band
      _ -> nil
    end
  end

  defp terminal?(ac, {alat, alon}) do
    is_number(ac.lat) and is_number(ac.lon) and is_number(ac.alt_ft) and
      fresh_position?(ac) and
      ac.alt_ft > 0 and ac.alt_ft < @terminal_ceiling_ft and
      (ac.vspeed_fpm || 0) < @climbing_fpm and
      distance_nm(ac.lat, ac.lon, alat, alon) <= @terminal_radius_nm
  end

  defp bound_here?(ac, {alat, alon} = airport) do
    d = distance_nm(ac.lat, ac.lon, alat, alon)

    cond do
      d <= @core_radius_nm and ac.alt_ft < @core_ceiling_ft -> true
      d > @closing_radius_nm or ac.alt_ft >= @closing_ceiling_ft -> false
      (ac.vspeed_fpm || 0) >= @descent_fpm -> false
      true -> closing_on?(ac, airport)
    end
  end

  # Heading within @closing_max_offset_deg of the bearing to the field. No track → no.
  defp closing_on?(%{track_deg: trk} = ac, {alat, alon}) when is_number(trk),
    do: angular_distance(trk, bearing_deg(ac.lat, ac.lon, alat, alon)) <= @closing_max_offset_deg

  defp closing_on?(_ac, _airport), do: false

  defp bearing_deg(lat1, lon1, lat2, lon2) do
    dn = (lat2 - lat1) * 60.0
    de = (lon2 - lon1) * 60.0 * :math.cos(rad(lat1))
    :math.atan2(de, dn) |> deg() |> normalise()
  end

  # Unknown age (feeds that do not report it) is treated as fresh.
  defp fresh_position?(%{pos_age_s: age}) when is_number(age), do: age <= @max_pos_age_s
  defp fresh_position?(_ac), do: true

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

  # A final is SLOW. The loop's outbound leg dips under 3000 ft within 6 nm of the field
  # at 266-272 kt; read as a final it named a runway that was not in use.
  @final_max_gs_kt 180

  defp arriving?(ac, {alat, alon}) do
    is_number(ac.lat) and is_number(ac.lon) and is_number(ac.track_deg) and
      is_number(ac.alt_ft) and ac.alt_ft < @approach_ceiling_ft and
      is_number(ac.gspeed_kt) and ac.gspeed_kt < @final_max_gs_kt and
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
