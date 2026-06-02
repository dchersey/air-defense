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

  alias LgaPredictor.{Actuator, ConfigStore, History, KeepAlive, Predictor}
  alias LgaPredictor.FR24.Client

  @credits_per_aircraft 6

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
    if connected != state.headphones_connected do
      Logger.info("[poller] headphones #{if connected, do: "connected — resuming", else: "disconnected — pausing"}")
      unless connected, do: Actuator.reset()
    end

    {:reply, :ok, %{state | headphones_connected: connected}}
  end

  @impl true
  def handle_info({:poll, id}, state) do
    # Ignore stale timers for a zoneset whose session has ended.
    if Map.has_key?(state.sessions, id), do: {:noreply, poll_tick(state, id)}, else: {:noreply, state}
  end

  def handle_info({:end_session, id}, state) do
    Logger.info("[poller] session #{id} auto-ended after duration")
    {:noreply, stop_one(state, id)}
  end

  ## Session lifecycle

  defp start_one(state, id) do
    # Reset stats only when starting from fully idle; the first session also asks
    # keep-alive to hold the audio route.
    state =
      if map_size(state.sessions) == 0 do
        notify_keep_alive(state, :on)
        %{state | polls: 0, credits: 0, actioned: MapSet.new()}
      else
        state
      end

    timer = Process.send_after(self(), {:end_session, id}, state.session_duration)
    ends_at = System.os_time(:second) + div(state.session_duration, 1000)

    Logger.info("[poller] session START #{id} — #{div(state.session_duration, 60_000)} min")

    state = %{state | sessions: Map.put(state.sessions, id, %{ends_at: ends_at, timer: timer})}
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
            suppress_until: Map.delete(state.suppress_until, id)
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
    notify_keep_alive(state, :off)
    Logger.info("[poller] all sessions ended — #{state.polls} polls, ~#{state.credits} credits")
    %{state | poll_timers: %{}, suppress_until: %{}}
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
        delay = if suppressed?(state, id), do: suppress_delay_ms(state, id), else: interval_ms(state, zoneset)
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

  defp suppressed?(state, id), do: Map.get(state.suppress_until, id, 0) > System.os_time(:second)

  defp suppress_delay_ms(state, id) do
    max(Map.get(state.suppress_until, id, 0) - System.os_time(:second), 0) * 1000
  end

  defp poll_zoneset(state, zoneset, config) do
    case state.fetcher.(zoneset.monitor_box) do
      {:ok, aircraft} ->
        spent = length(aircraft) * @credits_per_aircraft
        record_monthly_credits(spent)
        state = %{state | credits: state.credits + spent}

        aircraft
        |> Enum.reject(&ramp?/1)
        |> Enum.reduce(state, &consider(&1, zoneset, config, &2))

      {:error, reason} ->
        Logger.warning("[poller] fetch error (#{zoneset.id}): #{inspect(reason)} (skipping)")
        state
    end
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

      zoneset.trigger == :assume ->
        # Per-flight ETA from distance ÷ groundspeed (heading-independent), with
        # dwell capped. Falls back to the fixed assume window only if ETA can't be
        # computed (no groundspeed / no ANC zones).
        window =
          Predictor.predict_eta(ac, zoneset.anc_zones, max_dwell_seconds: config.max_dwell_seconds) ||
            assume_window(zoneset)

        dispatch(window, ac, key, config, zoneset.id, state)

      true ->
        case first_window(ac, zoneset, ceiling, state.window) do
          nil -> state
          window -> dispatch(window, ac, key, config, zoneset.id, state)
        end
    end
  end

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

  defp dispatch(window, ac, key, config, zoneset_id, state) do
    # Predictions assume zero latency; fire `latency` seconds early. The
    # engage/release deltas are the manual control-panel tuning offsets (±s).
    latency = config.anc_latency_seconds
    on_ms = max(round((window.enters_in - latency + config.engage_delta_seconds) * 1000), 0)
    off_ms = max(round((window.exits_in - latency + config.release_delta_seconds) * 1000), 0)

    dist_km = Float.round(window.enters_in * (ac.gspeed_kt || 0) * 1.852 / 3600, 2)

    Logger.info(
      "[poller] TRIGGER #{key} alt=#{ac.alt_ft}ft gs=#{ac.gspeed_kt}kt dist=#{dist_km}km " <>
        "enters in #{round(window.enters_in)}s, dwell #{round(window.dwell_seconds)}s"
    )

    record_history(%{
      at: System.os_time(:second),
      callsign: key,
      alt_ft: ac.alt_ft,
      enters_in: round(window.enters_in),
      dwell: round(window.dwell_seconds)
    })

    Actuator.cover(on_ms, off_ms, key)

    # Lock-on: stop polling this zoneset until the plane is predicted to clear the
    # ANC zone (the latest exit if several planes were caught in one poll).
    exits_at = System.os_time(:second) + round(window.exits_in)

    %{
      state
      | actioned: MapSet.put(state.actioned, key),
        suppress_until: Map.update(state.suppress_until, zoneset_id, exits_at, &max(&1, exits_at))
    }
  end

  # History is optional (tests may run Poller without it supervised).
  defp record_history(event) do
    if Process.whereis(History), do: History.record(event)
  end

  ## Status

  defp status_of(state) do
    config = state.config_fun.()

    zonesets =
      Enum.map(config.zonesets, fn zs ->
        session = Map.get(state.sessions, zs.id)
        %{id: zs.id, name: zs.name, active: session != nil, ends_at: session && session.ends_at}
      end)

    ends = state.sessions |> Map.values() |> Enum.map(& &1.ends_at)

    %{
      active?: map_size(state.sessions) > 0,
      polls: state.polls,
      approx_credits: state.credits,
      headphones_connected: state.headphones_connected,
      session_ends_at: if(ends == [], do: nil, else: Enum.max(ends)),
      zonesets: zonesets
    }
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
      polls: 0,
      credits: 0,
      headphones_connected: true,
      actioned: MapSet.new(),
      fetcher: Keyword.get(opts, :fetcher, &default_fetch(&1, sandbox?)),
      config_fun: Keyword.get(opts, :config_fun, fn -> ConfigStore.get() end),
      keep_alive_fun: Keyword.get(opts, :keep_alive_fun, &default_keep_alive/1),
      window: Keyword.get(opts, :window_seconds, Application.get_env(:lga_predictor, :prediction_window_seconds, 120)),
      poll_interval: Keyword.get(opts, :poll_interval_ms, Application.get_env(:lga_predictor, :poll_interval_ms, 60_000)),
      session_duration: Keyword.get(opts, :session_duration_ms, Application.get_env(:lga_predictor, :session_duration_ms, 4 * 60 * 60 * 1000))
    }
  end

  defp default_fetch(box, sandbox?) do
    Client.positions(box, :light, sandbox?: sandbox?)
  end
end
