defmodule LgaPredictor.Poller do
  @moduledoc """
  The session loop. Each **zoneset** has its own independent monitoring session
  (started/stopped by id from the control panel); both arrival and departure
  zonesets can run at once. Each running zoneset polls FR24 on **its own timer**
  at its `poll_interval_ms` (falling back to the global default) for its monitor
  zone (the only thing that costs credits), predicts whether each detected flight
  will pass through its ANC zones, and schedules ANC engage/release with the
  `Actuator`. Each session runs for `session_duration_ms` (4 h) or until stopped.

  **Lock-on:** once a zoneset detects a qualifying flight it stops polling until
  that flight is predicted to clear the ANC zone (`exits_in`), then resumes — so a
  narrow, frequently-polled zone tracks one plane at a time without re-spending
  credits during the pass.

  Idle by default — nothing is polled (and no credits spent) until a session is
  started. Stats reset when starting from fully idle and accumulate across
  concurrently-running sessions.

  Config comes from `ConfigStore` via an injectable `:config_fun`. FR24 fetching is
  injectable via `:fetcher` so the loop is testable offline. ANC timing fires
  `anc_latency_seconds` early; a flight is actioned at most once per session.
  """

  use GenServer
  require Logger

  alias LgaPredictor.{Actuator, ConfigStore, Geo, History, KeepAlive, Predictor}

  @credits_per_aircraft 6

  # Arrivals ramp from their slow monitor cadence to this fast cadence once a flight is
  # within `@arrival_ramp_seconds` (ETA) of the ANC zone, so we catch its actual entry.
  # ETA decides WHEN to ramp; the fast poll then drives the engage.
  @ramp_poll_interval_ms 3000
  @arrival_ramp_seconds 90

  ## API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Begin a monitoring session for a single zoneset by id."
  def start_session(zoneset_id) when is_binary(zoneset_id),
    do: GenServer.call(__MODULE__, {:start_session, zoneset_id})

  @doc "Begin sessions for every enabled zoneset."
  def start_session, do: GenServer.call(__MODULE__, :start_session)

  @doc "End the monitoring session for a single zoneset by id."
  def stop_session(zoneset_id) when is_binary(zoneset_id),
    do: GenServer.call(__MODULE__, {:stop_session, zoneset_id})

  @doc "End all sessions, stop polling, return to Transparency."
  def stop_session, do: GenServer.call(__MODULE__, :stop_session)

  @doc "Session status: active?, per-zoneset session state, polls, credits."
  def status, do: GenServer.call(__MODULE__, :status)

  @doc """
  Report whether the AirPods are the active output. When disconnected, active
  sessions keep their timers running but PAUSE polling (no FR24 credits) and
  resume automatically when they reconnect.
  """
  def set_headphones(connected) when is_boolean(connected),
    do: GenServer.call(__MODULE__, {:set_headphones, connected})

  ## Server

  @impl true
  def init(opts), do: {:ok, build_state(opts)}

  @impl true
  def handle_call({:start_session, id}, _from, state) do
    cond do
      Map.has_key?(state.sessions, id) -> {:reply, {:error, :already_active}, state}
      not zoneset_exists?(id, state) -> {:reply, {:error, :unknown_zoneset}, state}
      true -> {:reply, :ok, start_one(state, id)}
    end
  end

  def handle_call(:start_session, _from, state) do
    state =
      Enum.reduce(enabled_ids(state), state, fn id, st ->
        if Map.has_key?(st.sessions, id), do: st, else: start_one(st, id)
      end)

    {:reply, :ok, state}
  end

  def handle_call({:stop_session, id}, _from, state), do: {:reply, :ok, stop_one(state, id)}
  def handle_call(:stop_session, _from, state), do: {:reply, :ok, stop_all(state)}

  def handle_call(:status, _from, state), do: {:reply, status_of(state), state}

  def handle_call({:set_headphones, connected}, _from, state) do
    state =
      if connected != state.headphones_connected do
        Logger.info(
          "[poller] headphones #{if connected, do: "connected — resuming", else: "disconnected — pausing"}"
        )

        unless connected, do: Actuator.reset()
        # Release our keep-alive hold while the buds are gone (let the route idle)
        # and re-acquire it on reconnect.
        reconcile_keep_alive(%{state | headphones_connected: connected})
      else
        state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_info({:poll, id}, state) do
    # Ignore stale timers for a zoneset whose session has ended.
    if Map.has_key?(state.sessions, id),
      do: {:noreply, poll_tick(state, id)},
      else: {:noreply, state}
  end

  def handle_info({:end_session, id}, state) do
    Logger.info("[poller] session #{id} auto-ended after duration")
    {:noreply, stop_one(state, id)}
  end

  ## Session lifecycle

  defp start_one(state, id) do
    # Reset stats only when starting from fully idle.
    state =
      if map_size(state.sessions) == 0 do
        %{state | polls: 0, credits: 0, actioned: MapSet.new(), engaged: MapSet.new()}
      else
        state
      end

    timer = Process.send_after(self(), {:end_session, id}, state.session_duration)
    ends_at = System.os_time(:second) + div(state.session_duration, 1000)

    Logger.info("[poller] session START #{id} — #{div(state.session_duration, 60_000)} min")

    state = %{state | sessions: Map.put(state.sessions, id, %{ends_at: ends_at, timer: timer})}
    # Hold the audio route only while the AirPods are actually connected.
    state = reconcile_keep_alive(state)
    # Poll this zoneset right away, then on its own per-zoneset cadence.
    poll_tick(state, id)
  end

  defp stop_one(state, id) do
    case Map.pop(state.sessions, id) do
      {nil, _} ->
        state

      {%{timer: timer}, sessions} ->
        Process.cancel_timer(timer)
        cancel_poll(state, id)
        Logger.info("[poller] session END #{id}")

        state = %{
          state
          | sessions: sessions,
            poll_timers: Map.delete(state.poll_timers, id),
            suppress_until: Map.delete(state.suppress_until, id),
            intercepts: Map.delete(state.intercepts, id)
        }

        if map_size(sessions) == 0, do: go_idle(state), else: state
    end
  end

  defp stop_all(state) do
    Enum.each(state.sessions, fn {_id, %{timer: t}} -> Process.cancel_timer(t) end)
    go_idle(%{state | sessions: %{}})
  end

  defp go_idle(state) do
    Enum.each(state.poll_timers, fn {_id, ref} -> Process.cancel_timer(ref) end)
    Actuator.reset()
    state = reconcile_keep_alive(state)
    Logger.info("[poller] all sessions ended — #{state.polls} polls, ~#{state.credits} credits")
    %{state | poll_timers: %{}, suppress_until: %{}, intercepts: %{}, engaged: MapSet.new()}
  end

  # Push/pop our single keep-alive hold so it's held exactly while a session is
  # active AND the AirPods are connected: when the buds disconnect we release the
  # hold (let the route idle) and re-acquire it on reconnect. `keep_alive_held`
  # guards the LIFO so we never double-push or double-pop.
  defp reconcile_keep_alive(state) do
    want = map_size(state.sessions) > 0 and state.headphones_connected

    cond do
      want and not state.keep_alive_held ->
        notify_keep_alive(state, :on)
        %{state | keep_alive_held: true}

      not want and state.keep_alive_held ->
        notify_keep_alive(state, :off)
        %{state | keep_alive_held: false}

      true ->
        state
    end
  end

  # Best-effort — must never crash the session loop if keep-alive is down.
  defp notify_keep_alive(state, which) do
    state.keep_alive_fun.(which)
  rescue
    _ -> :ok
  end

  defp default_keep_alive(which) do
    if Application.get_env(:lga_predictor, :keep_alive_enabled, true) do
      case which do
        :on -> KeepAlive.on()
        :off -> KeepAlive.off()
      end
    end
  end

  ## Polling (one timer per zoneset)

  defp poll_tick(state, id) do
    config = state.config_fun.()
    zoneset = Enum.find(config.zonesets, &(&1.id == id))

    cond do
      is_nil(zoneset) ->
        # Zoneset removed from config — drop its timer.
        cancel_poll(state, id)
        %{state | poll_timers: Map.delete(state.poll_timers, id)}

      not state.headphones_connected ->
        # Paused: session timer keeps running, no FR24 fetch / credits. Keep
        # ticking so we resume promptly on reconnect.
        Logger.info("[poller] #{id}: poll skipped — headphones disconnected (paused)")
        reschedule_poll(state, id, interval_ms(state, zoneset))

      suppressed?(state, id) ->
        # Locked onto a plane — resume when it's predicted to clear the ANC zone.
        reschedule_poll(state, id, suppress_delay_ms(state, id))

      true ->
        state = state |> poll_zoneset(zoneset, config) |> bump_polls(id)

        delay =
          cond do
            suppressed?(state, id) -> suppress_delay_ms(state, id)
            # An armed (approaching) flight → ramp to the fast cadence to catch its
            # ACTUAL zone entry (but never slower than the zoneset's own interval).
            # ETA decides when arming begins (consider_arrival).
            ramping?(state, id) -> min(@ramp_poll_interval_ms, interval_ms(state, zoneset))
            true -> interval_ms(state, zoneset)
          end

        reschedule_poll(state, id, delay)
    end
  end

  defp bump_polls(state, id) do
    state = %{state | polls: state.polls + 1}
    Logger.info("[poller] poll #{id} ##{state.polls}; session ~#{state.credits} cr")
    state
  end

  defp reschedule_poll(state, id, delay_ms) do
    cancel_poll(state, id)
    ref = Process.send_after(self(), {:poll, id}, max(round(delay_ms), 0))
    %{state | poll_timers: Map.put(state.poll_timers, id, ref)}
  end

  defp cancel_poll(state, id) do
    if ref = state.poll_timers[id], do: Process.cancel_timer(ref)
    :ok
  end

  defp interval_ms(state, zoneset), do: zoneset.poll_interval_ms || state.poll_interval

  # Poll the UNION of the monitor zone + the ANC zone (+ margin): the monitor zone
  # puts the plane "on radar", the union spans any gap between the two so the plane is
  # never lost, and the ANC-zone coverage lets BOTH arrivals and departures engage on
  # the ACTUAL (about-to-)entry. Activation timing lives in consider_arrival/
  # consider_departure (engage only when in/entering the ANC zone) — the wide box only
  # governs which flights we can see.
  @departure_margin_deg 0.02
  defp query_box(zoneset), do: tracking_box(zoneset)

  defp tracking_box(zoneset) do
    boxes = [zoneset.monitor_box | Enum.map(zoneset.anc_zones, &Geo.bbox/1)]
    m = @departure_margin_deg
    n = boxes |> Enum.map(&elem(&1, 0)) |> Enum.max()
    s = boxes |> Enum.map(&elem(&1, 1)) |> Enum.min()
    w = boxes |> Enum.map(&elem(&1, 2)) |> Enum.min()
    e = boxes |> Enum.map(&elem(&1, 3)) |> Enum.max()
    {n + m, s - m, w - m, e + m}
  end

  defp suppressed?(state, id), do: Map.get(state.suppress_until, id, 0) > System.os_time(:second)

  # An armed (approaching, not-yet-engaged) leg means a flight is closing on the ANC
  # zone → poll fast to catch its actual entry.
  defp ramping?(state, id) do
    now = System.os_time(:second)

    state.intercepts
    |> Map.get(id, [])
    |> Enum.any?(&(Map.get(&1, :approaching, false) and &1.exits_at > now))
  end

  defp suppress_delay_ms(state, id) do
    max(Map.get(state.suppress_until, id, 0) - System.os_time(:second), 0) * 1000
  end

  defp poll_zoneset(state, zoneset, config) do
    case state.fetcher.(query_box(zoneset)) do
      {:ok, aircraft} ->
        spent = length(aircraft) * @credits_per_aircraft
        record_monthly_credits(spent)
        state = %{state | credits: state.credits + spent}

        state =
          aircraft
          |> Enum.reject(&ramp?/1)
          |> Enum.reduce(state, &consider(&1, zoneset, config, &2))

        # Sweep this zoneset's intercept legs for flights no longer in the feed (flew
        # out of the box, or an ADS-B dropout) so a vanished plane never leaves a
        # phantom inbound/overhead marker lingering in the UI. The Actuator releases
        # ANC on its own as the last hold lapses.
        sweep_legs(state, zoneset.id, MapSet.new(aircraft, &(&1.hex || &1.callsign)))

      {:error, reason} ->
        Logger.warning("[poller] fetch error (#{zoneset.id}): #{inspect(reason)} (skipping)")
        state
    end
  end

  defp sweep_legs(state, zoneset_id, seen_keys) do
    kept =
      state.intercepts
      |> Map.get(zoneset_id, [])
      |> Enum.filter(&MapSet.member?(seen_keys, Map.get(&1, :key)))

    %{state | intercepts: Map.put(state.intercepts, zoneset_id, kept)}
  end

  # Feed each poll's spend into the month-to-date self-tally (skipped in tests,
  # where the ledger isn't started).
  defp record_monthly_credits(0), do: :ok

  defp record_monthly_credits(spent) do
    if Process.whereis(LgaPredictor.CreditLedger), do: LgaPredictor.CreditLedger.add(spent)
    :ok
  end

  # Parked/taxiing aircraft: no position-relevant motion, don't pay attention.
  defp ramp?(ac), do: (ac.alt_ft || 0) == 0 or (ac.gspeed_kt || 0) == 0

  # Per-zone-type engage-lead bias (same units/sign as the manual `engage_delta`
  # slider; positive = engage later). BOTH zone types now engage on the ACTUAL
  # ANC-zone entry detected by fast polling; this fine-tunes the small dead-reckoning
  # lead. Arrivals: 0 (lead 0 → engage when actually at the boundary, never early —
  # ANC ramps up over its latency as the plane proceeds toward the louder overhead
  # centre). Departures: 6, tuned on-aircraft. The slider sits at 0 and shifts both.
  @arrival_engage_bias 0
  @departure_engage_bias 6

  # Effective ANC timing offsets: a zoneset's own offset overrides the global one
  # (nil → global). Arrival and departure zones have different geometry, so a single
  # global pair forced a re-tune on every zone switch; per-zone keeps each calibrated.
  defp engage_delta(zoneset, config),
    do: Map.get(zoneset, :engage_delta_seconds) || config.engage_delta_seconds || 0

  defp release_delta(zoneset, config),
    do: Map.get(zoneset, :release_delta_seconds) || config.release_delta_seconds || 0

  defp consider(ac, zoneset, config, state) do
    key = ac.hex || ac.callsign
    ceiling = zoneset.altitude_ceiling_ft || config.global_ceiling_ft

    cond do
      MapSet.member?(state.actioned, key) ->
        state

      (ac.alt_ft || 0) >= ceiling ->
        state

      # Below the zoneset's groundspeed floor — slow non-jet traffic
      # (helicopters / GA / junk) we don't want driving ANC.
      (ac.gspeed_kt || 0) < (zoneset.min_gspeed_kt || 0) ->
        state

      zoneset.type == :departure ->
        consider_departure(ac, zoneset, key, config, state)

      zoneset.trigger == :assume ->
        consider_arrival(ac, zoneset, key, config, state)

      true ->
        case first_window(ac, zoneset, ceiling, state.window) do
          nil -> state
          window -> dispatch(window, ac, key, config, zoneset, state)
        end
    end
  end

  # Arrival zones: ANC engages on the ACTUAL detected ANC-zone entry (fast polling),
  # not a far-out ETA — long-range dead-reckoning mis-timed the engage (3–10 s early).
  # The ETA is still used, but only to decide WHEN to ramp to the fast cadence
  # (arming). Release stays the predicted-dwell lock-on, which times the cutoff well.
  defp consider_arrival(ac, zoneset, key, config, state) do
    zones = zoneset.anc_zones

    window =
      Predictor.predict_eta(ac, zones, max_dwell_seconds: config.max_dwell_seconds) ||
        assume_window(zoneset)

    latency = config.anc_latency_seconds || 0.0
    # Engage when the plane is ACTUALLY at the boundary — no forward lead by default
    # (the user wants no early trigger; the predicted ETA proved too eager). The slider
    # still shifts it: +engage_delta → negative lead → engage deeper; −engage_delta →
    # positive lead → engage earlier. Same sign convention as departures, and per-zone.
    lead = -engage_delta(zoneset, config) - @arrival_engage_bias
    now = System.os_time(:second)

    cur_in? = in_any_zone?(zones, {ac.lat, ac.lon})
    {fx, fy} = project_ahead(ac, max(lead, 0.0))
    entering? = cur_in? or in_any_zone?(zones, {fx, fy})

    cond do
      entering? ->
        # Engage now (on actual entry); release on the predicted dwell (lock-on until
        # the plane is predicted to clear — mirrors dispatch/6's release).
        off_ms =
          max(round((window.exits_in - latency + release_delta(zoneset, config)) * 1000), 0)

        Actuator.cover(0, off_ms, key)
        exits_at = now + round(window.exits_in)

        record_history(%{
          at: now,
          callsign: ac.callsign,
          hex: ac.hex,
          alt_ft: ac.alt_ft,
          enters_in: 0,
          dwell: round(window.dwell_seconds)
        })

        Logger.info(
          "[poller] ARRIVE #{key} alt=#{ac.alt_ft}ft gs=#{ac.gspeed_kt}kt — ANC on (clear in ~#{round(window.dwell_seconds)}s)"
        )

        %{
          state
          | actioned: MapSet.put(state.actioned, key),
            suppress_until:
              Map.update(state.suppress_until, zoneset.id, exits_at, &max(&1, exits_at))
        }
        |> put_leg(zoneset.id, key, ac,
          engage_at: now,
          exits_at: exits_at,
          approaching: false,
          tracked: false
        )

      passed_zone?(ac, zones) ->
        # Missed the zone (past its latitude band on the side it's heading) → abandon.
        %{state | actioned: MapSet.put(state.actioned, key)} |> drop_leg(zoneset.id, key)

      tracking_arrival?(state, zoneset.id, key) or
          (window.enters_in <= @arrival_ramp_seconds and approaching?(ac, zones, lead)) ->
        # Arm (amber) and ramp to the fast cadence to catch the actual entry — and KEEP
        # it armed once tracking has begun, so the indicator doesn't flicker back to
        # green in the gap between the monitor and ANC zones (where the monitor zone no
        # longer contains the plane) or when a single poll's ETA/approaching check
        # wavers. It clears only on actual entry (engage, above), a confirmed miss
        # (passed_zone?, above), or the flight vanishing from the feed (sweep_legs).
        # engage_at carries the ETA estimate for the inbound countdown; approaching:
        # true keeps it from flipping to "engaged" before the plane is actually
        # detected in the zone.
        #
        # Predict the ACTUAL engage moment, not the geometric boundary crossing: the
        # trigger fires when the flight is `lead` seconds (forward dead-reckoning) from
        # the zone, so it engages at enters_in - lead. `lead` already folds in the
        # per-zone engage offset and the arrival bias, so the amber countdown lands on
        # the same instant the red banner appears instead of running ~latency ahead of it.
        est = now + max(round(window.enters_in - lead), 0)

        put_leg(state, zoneset.id, key, ac,
          engage_at: est,
          exits_at: now + round(window.exits_in),
          approaching: true,
          tracked: false
        )

      true ->
        # On radar but still beyond the ramp (or not closing) and not yet tracked → no
        # leg; keep the slow monitor cadence until the ETA pulls it inside the ramp.
        drop_leg(state, zoneset.id, key)
    end
  end

  # Already tracking this flight as an inbound (amber) arrival? Used to hold the armed
  # state once it's begun rather than re-deciding from scratch each poll.
  defp tracking_arrival?(state, zid, key) do
    match?(%{approaching: true}, find_leg(state, zid, key))
  end

  # Departure zones: turn points vary, so don't schedule from a far-out ETA. Track
  # at the zoneset's fast cadence and engage only when the flight is *at* the ANC
  # zone — now, or projected `anc_latency` ahead (so ANC is on as it crosses in, and
  # near-misses whose projected point stays outside never trigger). Once a flight has
  # gone past the zone's latitude band on the side it's heading, abandon it.
  defp consider_departure(ac, zoneset, key, config, state) do
    # `lead` is the effective engage horizon, matching the arrival path exactly:
    # arrivals fire at enters_in == latency - engage_delta (see dispatch/6). It can be
    # NEGATIVE (engage_delta > latency means "engage that many seconds AFTER the plane
    # reaches the zone" — a deliberate late engage the user tuned for arrivals).
    lead =
      (config.anc_latency_seconds || 0.0) - engage_delta(zoneset, config) - @departure_engage_bias

    zones = zoneset.anc_zones

    cur_in? = in_any_zone?(zones, {ac.lat, ac.lon})
    # Hold while overhead — look only forward (bridges the early-engage gap + the exit
    # between polls); never backward, or we'd hold after the plane has left.
    {fx, fy} = project_ahead(ac, max(lead, 0.0))
    overhead? = cur_in? or in_any_zone?(zones, {fx, fy})

    # First-engage moment. Positive lead: engage early/at entry (forward projection).
    # Negative lead: engage only once the plane's position `|lead|`s ago was already
    # in the zone — i.e. it's been inside |lead|s — so the engage lands after entry,
    # matching arrivals.
    engage_now? =
      if lead >= 0.0 do
        overhead?
      else
        {bx, by} = project_ahead(ac, lead)
        in_any_zone?(zones, {bx, by})
      end

    engaged? = MapSet.member?(state.engaged, key)
    now = System.os_time(:second)
    ttl = round(departure_hold_ms(zoneset, state) / 1000) + 2

    cond do
      engaged? and overhead? ->
        # Re-cover each poll to keep ANC on while overhead (the Actuator coalesces by
        # pushing the off time), so a banking path stays covered; release tracks the
        # ACTUAL exit. Refresh the leg (keep the original engage time).
        Actuator.cover(0, departure_hold_ms(zoneset, state), key)
        engage_at = (find_leg(state, zoneset.id, key) || %{engage_at: now}).engage_at || now
        put_leg(state, zoneset.id, key, ac, engage_at: engage_at, exits_at: now + ttl)

      engaged? ->
        # Was overhead, now gone from the zone: stop holding (ANC releases as the last
        # hold lapses) and don't re-engage it this session.
        %{
          state
          | engaged: MapSet.delete(state.engaged, key),
            actioned: MapSet.put(state.actioned, key)
        }
        |> drop_leg(zoneset.id, key)

      engage_now? ->
        Actuator.cover(0, departure_hold_ms(zoneset, state), key)
        dwell = departure_dwell(ac, zoneset, config)

        record_history(%{
          at: now,
          callsign: ac.callsign,
          hex: ac.hex,
          alt_ft: ac.alt_ft,
          enters_in: 0,
          dwell: round(dwell)
        })

        Logger.info(
          "[poller] DEPART #{key} alt=#{ac.alt_ft}ft gs=#{ac.gspeed_kt}kt — ANC on (release on exit)"
        )

        state
        |> Map.update!(:engaged, &MapSet.put(&1, key))
        |> put_leg(zoneset.id, key, ac, engage_at: now, exits_at: now + ttl)

      passed_zone?(ac, zones) ->
        %{state | actioned: MapSet.put(state.actioned, key)} |> drop_leg(zoneset.id, key)

      approaching?(ac, zones, lead) ->
        # On radar and closing on the zone, not yet overhead → inbound/armed (amber),
        # ANC still off. No engage time yet (departures engage on actual entry), so
        # the leg carries engage_at: nil — the UI shows "inbound", no countdown.
        put_leg(state, zoneset.id, key, ac,
          engage_at: nil,
          exits_at: now + ttl,
          approaching: true
        )

      true ->
        # On radar but not closing (e.g. a parallel fly-by) → clear any stale leg.
        drop_leg(state, zoneset.id, key)
    end
  end

  defp in_any_zone?(zones, point), do: Enum.any?(zones, &Geo.point_in_zone?(point, &1))

  # Closing-on-the-zone test for departures: dead-reckon a fixed lookahead and check
  # the distance to the nearest ANC zone shrinks. Distinguishes a real approach from a
  # parallel fly-by (whose distance grows). No track/groundspeed → not closing.
  @approach_lookahead_seconds 30.0
  defp approaching?(ac, anc_zones, lead) do
    {flat, flon} = project_ahead(ac, max(lead, @approach_lookahead_seconds))
    min_zone_distance(ac.lat, ac.lon, anc_zones) - min_zone_distance(flat, flon, anc_zones) > 0.0
  end

  defp min_zone_distance(lat, lon, anc_zones) do
    anc_zones |> Enum.map(&Geo.distance_to_zone({lat, lon}, &1)) |> Enum.min()
  end

  # Per-zoneset intercept legs are a list; departures upsert/remove by flight key.
  defp find_leg(state, zid, key) do
    state.intercepts |> Map.get(zid, []) |> Enum.find(&(Map.get(&1, :key) == key))
  end

  defp put_leg(state, zid, key, ac, fields) do
    now = System.os_time(:second)

    leg =
      Enum.into(fields, %{
        key: key,
        callsign: ac.callsign || ac.hex,
        approaching: false,
        # Departures are released on actual exit, not a predicted dwell — the UI shows
        # a live-tracking radar mark rather than a clear-by countdown.
        tracked: true
      })

    others =
      state.intercepts
      |> Map.get(zid, [])
      |> Enum.reject(&(Map.get(&1, :key) == key or &1.exits_at <= now))

    %{state | intercepts: Map.put(state.intercepts, zid, [leg | others])}
  end

  defp drop_leg(state, zid, key) do
    legs = state.intercepts |> Map.get(zid, []) |> Enum.reject(&(Map.get(&1, :key) == key))
    %{state | intercepts: Map.put(state.intercepts, zid, legs)}
  end

  # Per-poll ANC hold for a departure: comfortably longer than the poll cadence so
  # ANC never gaps between polls; it's the lag between the plane exiting and ANC
  # releasing. Released early-on-exit is the failure we're avoiding, so err long.
  defp departure_hold_ms(zoneset, state) do
    poll = zoneset.poll_interval_ms || state.poll_interval
    max(2 * poll, 7_000)
  end

  # Nominal dwell for history/UI only (the real release is exit-driven).
  defp departure_dwell(ac, zoneset, config) do
    case Predictor.predict_eta(ac, zoneset.anc_zones, max_dwell_seconds: config.max_dwell_seconds) do
      %{dwell_seconds: d} -> d
      _ -> zoneset.assume_duration_seconds
    end
  end

  # Dead-reckon `secs` ahead → {lat, lon}; falls back to the current point when
  # track/groundspeed are missing.
  defp project_ahead(%{track_deg: t, gspeed_kt: g} = ac, secs)
       when is_number(t) and is_number(g) do
    p = Geo.project(ac, secs)
    {p.lat, p.lon}
  end

  defp project_ahead(ac, _secs), do: {ac.lat, ac.lon}

  # True once the flight is beyond the ANC zones' latitude band on the side its track
  # is carrying it (north of the north edge heading north, or south of the south edge
  # heading south) — i.e. it has missed the zone. Bidirectional (works either side of
  # the airport). `cos(track)` is the north/south component (track 0° = north).
  defp passed_zone?(%{track_deg: t, lat: lat}, anc_zones)
       when is_number(t) and is_number(lat) and anc_zones != [] do
    boxes = Enum.map(anc_zones, &Geo.bbox/1)
    north = boxes |> Enum.map(&elem(&1, 0)) |> Enum.max()
    south = boxes |> Enum.map(&elem(&1, 1)) |> Enum.min()
    northward = :math.cos(t * :math.pi() / 180.0)
    (lat > north and northward > 0) or (lat < south and northward < 0)
  end

  defp passed_zone?(_ac, _zones), do: false

  # :assume fallback when ETA can't be computed: fixed delay + duration.
  defp assume_window(zoneset) do
    enters = zoneset.assume_delay_seconds
    exits = enters + zoneset.assume_duration_seconds
    %{enters_in: enters, exits_in: exits, dwell_seconds: zoneset.assume_duration_seconds}
  end

  # The earliest engage/release window across this zoneset's ANC zones.
  defp first_window(ac, zoneset, ceiling, window_seconds) do
    accel = if zoneset.reckoning == :accelerating, do: zoneset.accel_kt_s, else: 0.0

    zoneset.anc_zones
    |> Enum.map(fn zone ->
      Predictor.predict_overflight(ac,
        noise_zone: zone,
        window_seconds: window_seconds,
        altitude_ceiling_ft: ceiling,
        accel_kt_s: accel
      )
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(& &1.enters_in, fn -> nil end)
  end

  defp dispatch(window, ac, key, config, zoneset, state) do
    zoneset_id = zoneset.id
    # Predictions assume zero latency; fire `latency` seconds early. The
    # engage/release deltas are the manual control-panel tuning offsets (±s),
    # per-zone with a global fallback.
    latency = config.anc_latency_seconds

    on_ms =
      max(
        round(
          (window.enters_in - latency + engage_delta(zoneset, config) + @arrival_engage_bias) *
            1000
        ),
        0
      )

    off_ms = max(round((window.exits_in - latency + release_delta(zoneset, config)) * 1000), 0)

    dist_km = Float.round(window.enters_in * (ac.gspeed_kt || 0) * 1.852 / 3600, 2)

    Logger.info(
      "[poller] TRIGGER #{key} alt=#{ac.alt_ft}ft gs=#{ac.gspeed_kt}kt dist=#{dist_km}km " <>
        "enters in #{round(window.enters_in)}s, dwell #{round(window.dwell_seconds)}s"
    )

    record_history(%{
      at: System.os_time(:second),
      # Record the real broadcast callsign (for route lookup); keep the hex too.
      callsign: ac.callsign,
      hex: ac.hex,
      alt_ft: ac.alt_ft,
      enters_in: round(window.enters_in),
      dwell: round(window.dwell_seconds)
    })

    Actuator.cover(on_ms, off_ms, key)

    # Lock-on: stop polling this zoneset until the plane is predicted to clear the
    # ANC zone (the latest exit if several planes were caught in one poll).
    now = System.os_time(:second)
    exits_at = now + round(window.exits_in)
    engage_at = now + div(on_ms, 1000)

    # Record the intercept for the UI (armed/intercept/inbound), dropping any of
    # this zone's prior intercepts that have already cleared.
    # Arrivals are ETA-scheduled, so exits_at is a real prediction → the UI shows a
    # clear-by countdown (tracked: false). approaching: false — armed via engage_at.
    leg = %{
      key: key,
      callsign: ac.callsign || ac.hex,
      engage_at: engage_at,
      exits_at: exits_at,
      approaching: false,
      tracked: false
    }

    intercepts =
      Map.update(state.intercepts, zoneset_id, [leg], fn legs ->
        [leg | Enum.filter(legs, &(&1.exits_at > now))]
      end)

    %{
      state
      | actioned: MapSet.put(state.actioned, key),
        suppress_until:
          Map.update(state.suppress_until, zoneset_id, exits_at, &max(&1, exits_at)),
        intercepts: intercepts
    }
  end

  # History is optional (tests may run Poller without it supervised).
  defp record_history(event) do
    if Process.whereis(History), do: History.record(event)
  end

  ## Status

  defp status_of(state) do
    config = state.config_fun.()
    now = System.os_time(:second)

    zonesets =
      Enum.map(config.zonesets, fn zs ->
        session = Map.get(state.sessions, zs.id)
        legs = state.intercepts |> Map.get(zs.id, []) |> Enum.filter(&(&1.exits_at > now))
        armed = Enum.filter(legs, &armed_leg?(&1, now))

        phase =
          cond do
            session == nil -> "idle"
            Enum.any?(legs, &engaged_leg?(&1, now)) -> "engaged"
            armed != [] -> "armed"
            true -> "monitoring"
          end

        # Countdown only for armed legs with a real engage time (arrivals); an
        # approaching departure has none (engages on actual entry).
        intercept_at =
          armed |> Enum.map(& &1.engage_at) |> Enum.reject(&is_nil/1) |> Enum.min(fn -> nil end)

        %{
          id: zs.id,
          name: zs.name,
          active: session != nil,
          ends_at: session && session.ends_at,
          phase: phase,
          intercept_at: intercept_at,
          inbound: length(legs)
        }
      end)

    ends = state.sessions |> Map.values() |> Enum.map(& &1.ends_at)

    # Soonest still-armed intercept across all zones — drives the inbound banner.
    # Prefer one with a real engage time (arrival countdown); otherwise fall back to
    # an approaching departure (banner shows the route, "arming", no countdown).
    armed =
      state.intercepts |> Map.values() |> List.flatten() |> Enum.filter(&armed_leg?(&1, now))

    soonest =
      armed
      |> Enum.filter(&(&1.engage_at != nil))
      |> Enum.min_by(& &1.engage_at, fn -> nil end) ||
        List.first(armed)

    # Currently-overhead flight (ANC engaged) → the red banner. Soonest to clear.
    # Arrivals carry a real exit prediction (clear-by countdown); departures are
    # live-tracked (tracked: true → no countdown, a radar mark instead).
    overhead =
      state.intercepts
      |> Map.values()
      |> List.flatten()
      |> Enum.filter(&engaged_leg?(&1, now))
      |> Enum.min_by(& &1.exits_at, fn -> nil end)

    %{
      active?: map_size(state.sessions) > 0,
      polls: state.polls,
      approx_credits: state.credits,
      headphones_connected: state.headphones_connected,
      session_ends_at: if(ends == [], do: nil, else: Enum.max(ends)),
      zonesets: zonesets,
      inbound_at: soonest && soonest.engage_at,
      inbound_callsign: soonest && soonest.callsign,
      overhead_callsign: overhead && overhead.callsign,
      overhead_at:
        (overhead && not Map.get(overhead, :tracked, false) && overhead.exits_at) || nil
    }
  end

  # A leg is "armed" (inbound, amber) while it hasn't engaged yet: an approaching
  # departure, or an arrival whose scheduled engage is still in the future. "engaged"
  # once its real engage time has passed. (engage_at may be nil for approaching
  # departures — guard before comparing, since nil sorts above integers in Elixir.)
  defp armed_leg?(leg, now) do
    Map.get(leg, :approaching, false) or (leg.engage_at != nil and leg.engage_at > now)
  end

  defp engaged_leg?(leg, now) do
    not Map.get(leg, :approaching, false) and leg.engage_at != nil and leg.engage_at <= now
  end

  ## Helpers

  defp zoneset_exists?(id, state), do: Enum.any?(state.config_fun.().zonesets, &(&1.id == id))

  defp enabled_ids(state) do
    state.config_fun.().zonesets |> Enum.filter(& &1.enabled) |> Enum.map(& &1.id)
  end

  defp build_state(opts) do
    fr24 = Application.get_env(:lga_predictor, :fr24, %{})
    sandbox? = Keyword.get(opts, :sandbox?, Map.get(fr24, :sandbox?, false))

    %{
      sessions: %{},
      poll_timers: %{},
      suppress_until: %{},
      # Per-zoneset live intercepts (for the UI's armed/intercept/inbound display):
      # %{zoneset_id => [%{callsign, engage_at, exits_at}]} (unix seconds).
      intercepts: %{},
      # Departure flights currently held overhead (engage-and-hold; released on
      # actual exit, not a predicted dwell). MapSet of flight keys.
      engaged: MapSet.new(),
      polls: 0,
      credits: 0,
      headphones_connected: true,
      keep_alive_held: false,
      actioned: MapSet.new(),
      fetcher: Keyword.get(opts, :fetcher, &default_fetch(&1, sandbox?)),
      config_fun: Keyword.get(opts, :config_fun, fn -> ConfigStore.get() end),
      keep_alive_fun: Keyword.get(opts, :keep_alive_fun, &default_keep_alive/1),
      window:
        Keyword.get(
          opts,
          :window_seconds,
          Application.get_env(:lga_predictor, :prediction_window_seconds, 120)
        ),
      poll_interval:
        Keyword.get(
          opts,
          :poll_interval_ms,
          Application.get_env(:lga_predictor, :poll_interval_ms, 60_000)
        ),
      session_duration:
        Keyword.get(
          opts,
          :session_duration_ms,
          Application.get_env(:lga_predictor, :session_duration_ms, 4 * 60 * 60 * 1000)
        )
    }
  end

  # Resolve the provider from config at call time, so switching it in the app
  # settings takes effect without restarting a session.
  defp default_fetch(box, sandbox?) do
    provider = ConfigStore.get().provider
    LgaPredictor.Sources.positions(box, provider, sandbox?: sandbox?)
  end
end
