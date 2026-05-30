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

  @doc "Force back to Transparency and clear any pending window (e.g. session end)."
  def reset, do: GenServer.call(__MODULE__, :reset)

  ## Server

  @impl true
  def init(_opts) do
    {:ok, %{mode: :transparency, anc_off_at: nil, disengage_timer: nil}}
  end

  @impl true
  def handle_cast({:cover, on_in_ms, off_in_ms, label}, state) do
    now = mono()

    if on_in_ms <= 0 do
      send(self(), {:engage, label})
    else
      Process.send_after(self(), {:engage, label}, on_in_ms)
    end

    off_at = now + max(off_in_ms, 0)
    state = %{state | anc_off_at: max(state.anc_off_at || off_at, off_at)}
    {:noreply, reschedule_disengage(state, now)}
  end

  @impl true
  def handle_info({:engage, label}, state), do: {:noreply, engage(state, label)}

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

  def handle_call(:reset, _from, state) do
    if state.disengage_timer, do: Process.cancel_timer(state.disengage_timer)
    {:reply, :ok, disengage(%{state | disengage_timer: nil})}
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
