defmodule LgaPredictor.Actuator do
  @moduledoc """
  Tracks the **desired** AirPods Max acoustic mode. Given predicted overhead
  windows it sets the desired mode to `:anc` slightly before a pass and back to
  `:transparency` after, **coalescing** overlapping/back-to-back windows into one
  continuous ANC period (it tracks the latest "off" time and keeps pushing the
  disengage).

  This process does NOT touch the headphones — the native macOS toggle requires
  Accessibility and lives in the Swift menu-bar app, which reads `mode/0` (via the
  localhost API) and mirrors it onto the AirPods. Here we only own the timing and
  the desired-mode state machine.
  """

  use GenServer
  require Logger

  @disengage_guard_ms 50

  ## API

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Ensure ANC is engaged across the window [now+on_in_ms, now+off_in_ms]."
  def cover(on_in_ms, off_in_ms, label), do: GenServer.cast(__MODULE__, {:cover, on_in_ms, off_in_ms, label})

  @doc "Current acoustic mode (`:anc` | `:transparency`)."
  def mode, do: GenServer.call(__MODULE__, :mode)

  @doc """
  Coarse phase for the UI: `:engaged` (ANC on), `:armed` (a window is scheduled
  but ANC hasn't engaged yet — i.e. a flight has been detected and ANC is
  pending), or `:idle` (nothing scheduled).
  """
  def phase, do: GenServer.call(__MODULE__, :phase)

  @doc "Force back to Transparency and clear any pending window (e.g. session end)."
  def reset, do: GenServer.call(__MODULE__, :reset)

  ## Server

  @impl true
  def init(_opts) do
    {:ok, %{mode: :transparency, anc_off_at: nil, disengage_timer: nil, pending: 0, epoch: 0}}
  end

  @impl true
  def handle_cast({:cover, on_in_ms, off_in_ms, label}, state) do
    # `hold_ms` is the dwell AFTER engagement. We defer setting `anc_off_at` until
    # the plane actually engages, so a plane that isn't loud yet can't extend a
    # window running now — that previously bridged the quiet gaps between
    # non-overlapping passes and held ANC on for minutes. `epoch` lets `reset`
    # neutralize any engage still scheduled.
    hold_ms = max(off_in_ms - max(on_in_ms, 0), 0)
    msg = {:engage, label, hold_ms, state.epoch}

    if on_in_ms <= 0 do
      send(self(), msg)
    else
      Process.send_after(self(), msg, on_in_ms)
    end

    {:noreply, %{state | pending: state.pending + 1}}
  end

  @impl true
  def handle_info({:engage, _label, _hold_ms, epoch}, %{epoch: current} = state)
      when epoch != current do
    # Stale engage from before a reset — drop it (pending was already cleared).
    {:noreply, state}
  end

  def handle_info({:engage, label, hold_ms, _epoch}, state) do
    now = mono()
    off_at = now + hold_ms

    state = %{
      state
      | pending: max(state.pending - 1, 0),
        anc_off_at: max(state.anc_off_at || off_at, off_at)
    }

    {:noreply, reschedule_disengage(engage(state, label), now)}
  end

  def handle_info(:disengage, state) do
    now = mono()

    if state.anc_off_at && now >= state.anc_off_at - @disengage_guard_ms do
      {:noreply, disengage(state)}
    else
      {:noreply, reschedule_disengage(state, now)}
    end
  end

  @impl true
  def handle_call(:mode, _from, state), do: {:reply, state.mode, state}

  def handle_call(:phase, _from, state) do
    phase =
      cond do
        state.mode == :anc -> :engaged
        state.pending > 0 -> :armed
        true -> :idle
      end

    {:reply, phase, state}
  end

  def handle_call(:reset, _from, state) do
    if state.disengage_timer, do: Process.cancel_timer(state.disengage_timer)
    # Bump epoch so any engage still scheduled is ignored; clear pending.
    state = disengage(%{state | disengage_timer: nil})
    {:reply, :ok, %{state | pending: 0, epoch: state.epoch + 1}}
  end

  ## Internals

  defp engage(%{mode: :anc} = state, _label), do: state

  defp engage(state, label) do
    Logger.info("[actuator] desired mode -> ANC#{suffix(label)}")
    %{state | mode: :anc}
  end

  defp disengage(%{mode: :transparency} = state), do: %{state | anc_off_at: nil}

  defp disengage(state) do
    Logger.info("[actuator] desired mode -> transparency")
    %{state | mode: :transparency, anc_off_at: nil}
  end

  defp reschedule_disengage(state, now) do
    if state.disengage_timer, do: Process.cancel_timer(state.disengage_timer)
    delay = max((state.anc_off_at || now) - now, 0)
    %{state | disengage_timer: Process.send_after(self(), :disengage, delay)}
  end

  defp suffix(nil), do: ""
  defp suffix(label), do: " for #{label}"

  defp mono, do: System.monotonic_time(:millisecond)
end
