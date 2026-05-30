defmodule LgaPredictor.Actuator do
  @moduledoc """
  Owns the AirPods Max acoustic mode. Given predicted overhead windows it engages
  ANC slightly before a pass and returns to Transparency after, **coalescing**
  overlapping/back-to-back windows into one continuous ANC period (it tracks the
  latest "off" time and keeps pushing the disengage).

  In stub mode (default) it only logs "WOULD ENGAGE/DISENGAGE"; with `stub?: false`
  it runs the macOS Shortcuts `ANC On` / `ANC Off`.
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
    cfg = Application.get_env(:lga_predictor, :actuator, %{})

    {:ok,
     %{
       mode: :transparency,
       anc_off_at: nil,
       disengage_timer: nil,
       stub?: Map.get(cfg, :stub?, true),
       on_name: Map.get(cfg, :anc_on, "ANC On"),
       off_name: Map.get(cfg, :anc_off, "ANC Off")
     }}
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
    command(state, state.on_name, "ENGAGE ANC", label)
    %{state | mode: :anc}
  end

  defp disengage(%{mode: :transparency} = state), do: %{state | anc_off_at: nil}

  defp disengage(state) do
    command(state, state.off_name, "DISENGAGE ANC -> transparency", nil)
    %{state | mode: :transparency, anc_off_at: nil}
  end

  defp reschedule_disengage(state, now) do
    if state.disengage_timer, do: Process.cancel_timer(state.disengage_timer)
    delay = max((state.anc_off_at || now) - now, 0)
    %{state | disengage_timer: Process.send_after(self(), :disengage, delay)}
  end

  defp command(%{stub?: true}, _name, action, label) do
    Logger.info("[actuator:stub] WOULD #{action}#{suffix(label)}")
  end

  defp command(%{stub?: false} = state, name, action, label) do
    Logger.info("[actuator] #{action}#{suffix(label)} (shortcuts run #{inspect(name)})")
    _ = System.cmd("shortcuts", ["run", name], stderr_to_stdout: true)
    state
  end

  defp suffix(nil), do: ""
  defp suffix(label), do: " for #{label}"

  defp mono, do: System.monotonic_time(:millisecond)
end
