defmodule LgaPredictor.Poller do
  @moduledoc """
  The session loop. While a session is active it polls FR24 for low aircraft in
  the approach box every `poll_interval_ms`, asks the `Predictor` which ones will
  cross the noise zone, and hands those windows to the `Actuator`. A session runs
  for `session_duration_ms` (4 h) or until `stop_session/0`.

  Idle by default — nothing is polled (and no credits spent) until `start_session/0`.
  The FR24 fetch is injectable (`:fetcher`) so the loop is testable offline.
  """

  use GenServer
  require Logger

  alias LgaPredictor.{Actuator, History, Predictor}
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
    state =
      case state.fetcher.(state) do
        {:ok, aircraft} -> handle_aircraft(state, aircraft)
        {:error, reason} -> log_error(state, reason)
      end

    %{state | poll_timer: Process.send_after(self(), :poll, state.poll_interval)}
  end

  defp handle_aircraft(state, aircraft) do
    credits = state.credits + length(aircraft) * @credits_per_aircraft

    windows =
      Predictor.overflight_windows(aircraft,
        noise_zone: state.zone,
        window_seconds: state.window,
        altitude_ceiling_ft: state.ceiling
      )

    Enum.each(windows, &dispatch_window(&1, state))

    Logger.info(
      "[poller] poll ##{state.polls + 1}: #{length(aircraft)} aircraft (~#{length(aircraft) * @credits_per_aircraft} cr), " <>
        "#{length(windows)} heading to noise zone; session ~#{credits} cr"
    )

    %{state | polls: state.polls + 1, credits: credits}
  end

  defp dispatch_window(window, state) do
    ac = window.aircraft
    on_ms = max(round((window.enters_in - state.lead) * 1000), 0)
    off_ms = round((window.exits_in + state.tail) * 1000)

    Logger.info(
      "[poller] TRIGGER #{ac.callsign || ac.hex} alt=#{ac.alt_ft}ft gs=#{ac.gspeed_kt}kt " <>
        "enters in #{round(window.enters_in)}s, dwell #{round(window.dwell_seconds)}s"
    )

    record_history(%{
      at: System.os_time(:second),
      callsign: ac.callsign || ac.hex,
      alt_ft: ac.alt_ft,
      enters_in: round(window.enters_in),
      dwell: round(window.dwell_seconds)
    })

    Actuator.cover(on_ms, off_ms, ac.callsign || ac.hex)
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

  defp log_error(state, reason) do
    Logger.warning("[poller] fetch error: #{inspect(reason)} (skipping this poll)")
    state
  end

  # NOTE: FR24 rejects the altitude_ranges param on this plan (500/400), so we
  # fetch the whole box and let the Predictor filter by altitude. We pay 6 cr for
  # every returned aircraft including high cruisers — box size is the cost lever.
  defp default_fetch(state) do
    Client.positions(state.box, :light, sandbox?: state.sandbox?)
  end

  defp build_state(opts) do
    get = fn key, default ->
      Keyword.get(opts, key, Application.get_env(:lga_predictor, key, default))
    end

    fr24 = Application.get_env(:lga_predictor, :fr24, %{})

    %{
      active?: false,
      poll_timer: nil,
      session_timer: nil,
      session_ends_at: nil,
      polls: 0,
      credits: 0,
      fetcher: Keyword.get(opts, :fetcher, &default_fetch/1),
      zone: get.(:noise_zone, {:circle, {40.727, -73.860}, 1.0}),
      box: get.(:approach_box, {40.738, 40.678, -73.945, -73.850}),
      ceiling: get.(:altitude_ceiling_ft, 4500),
      floor: get.(:altitude_floor_ft, 0),
      window: get.(:prediction_window_seconds, 120),
      poll_interval: get.(:poll_interval_ms, 60_000),
      session_duration: get.(:session_duration_ms, 4 * 60 * 60 * 1000),
      lead: get.(:anc_lead_seconds, 8),
      tail: get.(:anc_tail_seconds, 12),
      sandbox?: Keyword.get(opts, :sandbox?, Map.get(fr24, :sandbox?, false))
    }
  end
end
