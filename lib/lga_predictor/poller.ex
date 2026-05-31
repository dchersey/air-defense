defmodule LgaPredictor.Poller do
  @moduledoc """
  The session loop. While a session is active it polls FR24 once per
  `poll_interval_ms` for each **enabled zoneset's monitor zone** (the only thing
  that costs credits), predicts whether each detected flight will pass through that
  zoneset's ANC zones, and schedules ANC engage/release with the `Actuator`. A
  session runs for `session_duration_ms` (4 h) or until `stop_session/0`.

  Idle by default — nothing is polled (and no credits spent) until `start_session/0`.

  Config (zonesets, global ceiling, ANC latency) comes from `ConfigStore` via an
  injectable `:config_fun`. FR24 fetching is injectable via `:fetcher` (a
  `box -> {:ok, [aircraft]} | {:error, _}` function) so the loop is testable offline.

  ANC timing: predictions assume zero actuator latency; each engage/release command
  is issued `anc_latency_seconds` EARLY so the mode is actually changed by the
  predicted moment. A flight is actioned at most once per session (de-duped by hex).
  """

  use GenServer
  require Logger

  alias LgaPredictor.{Actuator, ConfigStore, History, Predictor}
  alias LgaPredictor.FR24.Client

  @credits_per_aircraft 6

  ## API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Begin a monitoring session (polling + ANC control)."
  def start_session, do: GenServer.call(__MODULE__, :start_session)

  @doc "End the session, stop polling, return to Transparency."
  def stop_session, do: GenServer.call(__MODULE__, :stop_session)

  @doc "Session status: active?, polls run, approximate credits spent."
  def status, do: GenServer.call(__MODULE__, :status)

  ## Server

  @impl true
  def init(opts), do: {:ok, build_state(opts)}

  @impl true
  def handle_call(:start_session, _from, %{active?: true} = state) do
    {:reply, {:error, :already_active}, state}
  end

  def handle_call(:start_session, _from, state) do
    Logger.info("[poller] session START — polling every #{state.poll_interval}ms for #{div(state.session_duration, 60_000)} min")

    session_timer = Process.send_after(self(), :end_session, state.session_duration)
    ends_at = System.os_time(:second) + div(state.session_duration, 1000)

    state = %{
      state
      | active?: true,
        polls: 0,
        credits: 0,
        actioned: MapSet.new(),
        session_timer: session_timer,
        session_ends_at: ends_at
    }

    {:reply, :ok, poll_now(state)}
  end

  def handle_call(:stop_session, _from, state), do: {:reply, :ok, end_session(state)}

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       active?: state.active?,
       polls: state.polls,
       approx_credits: state.credits,
       session_ends_at: state.session_ends_at
     }, state}
  end

  @impl true
  def handle_info(:poll, %{active?: true} = state), do: {:noreply, poll_now(state)}
  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info(:end_session, state) do
    Logger.info("[poller] session auto-ended after duration")
    {:noreply, end_session(state)}
  end

  ## Internals

  defp poll_now(state) do
    config = state.config_fun.()
    enabled = Enum.filter(config.zonesets, & &1.enabled)

    state = Enum.reduce(enabled, state, &poll_zoneset(&1, config, &2))

    Logger.info("[poller] poll ##{state.polls + 1} done; session ~#{state.credits} cr")
    state = %{state | polls: state.polls + 1}
    %{state | poll_timer: Process.send_after(self(), :poll, state.poll_interval)}
  end

  defp poll_zoneset(zoneset, config, state) do
    case state.fetcher.(zoneset.monitor_box) do
      {:ok, aircraft} ->
        credits = state.credits + length(aircraft) * @credits_per_aircraft
        state = %{state | credits: credits}

        aircraft
        |> Enum.reject(&ramp?/1)
        |> Enum.reduce(state, &consider(&1, zoneset, config, &2))

      {:error, reason} ->
        Logger.warning("[poller] fetch error (#{zoneset.id}): #{inspect(reason)} (skipping)")
        state
    end
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

      zoneset.trigger == :assume ->
        dispatch(assume_window(zoneset), ac, key, config.anc_latency_seconds, state)

      true ->
        case first_window(ac, zoneset, ceiling, state.window) do
          nil -> state
          window -> dispatch(window, ac, key, config.anc_latency_seconds, state)
        end
    end
  end

  # :assume — detection in the monitor zone IS the trigger (for banking
  # departures where projecting a path into the ANC zone is unreliable). Engage
  # after a calibrated delay, hold for a calibrated duration.
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

  defp dispatch(window, ac, key, latency, state) do
    # Predictions assume zero latency; fire `latency` seconds early.
    on_ms = max(round((window.enters_in - latency) * 1000), 0)
    off_ms = max(round((window.exits_in - latency) * 1000), 0)

    Logger.info(
      "[poller] TRIGGER #{key} alt=#{ac.alt_ft}ft gs=#{ac.gspeed_kt}kt " <>
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
    %{state | actioned: MapSet.put(state.actioned, key)}
  end

  # History is optional (tests may run Poller without it supervised).
  defp record_history(event) do
    if Process.whereis(History), do: History.record(event)
  end

  defp end_session(state) do
    if state.poll_timer, do: Process.cancel_timer(state.poll_timer)
    if state.session_timer, do: Process.cancel_timer(state.session_timer)
    Actuator.reset()
    Logger.info("[poller] session END — #{state.polls} polls, ~#{state.credits} credits")
    %{state | active?: false, poll_timer: nil, session_timer: nil, session_ends_at: nil}
  end

  defp build_state(opts) do
    fr24 = Application.get_env(:lga_predictor, :fr24, %{})
    sandbox? = Keyword.get(opts, :sandbox?, Map.get(fr24, :sandbox?, false))

    %{
      active?: false,
      poll_timer: nil,
      session_timer: nil,
      session_ends_at: nil,
      polls: 0,
      credits: 0,
      actioned: MapSet.new(),
      fetcher: Keyword.get(opts, :fetcher, &default_fetch(&1, sandbox?)),
      config_fun: Keyword.get(opts, :config_fun, fn -> ConfigStore.get() end),
      window: Keyword.get(opts, :window_seconds, Application.get_env(:lga_predictor, :prediction_window_seconds, 120)),
      poll_interval: Keyword.get(opts, :poll_interval_ms, Application.get_env(:lga_predictor, :poll_interval_ms, 60_000)),
      session_duration: Keyword.get(opts, :session_duration_ms, Application.get_env(:lga_predictor, :session_duration_ms, 4 * 60 * 60 * 1000))
    }
  end

  defp default_fetch(box, sandbox?) do
    Client.positions(box, :light, sandbox?: sandbox?)
  end
end
