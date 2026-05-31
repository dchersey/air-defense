defmodule LgaPredictor.ActuatorTest do
  use ExUnit.Case

  alias LgaPredictor.Actuator

  setup do
    start_supervised!(Actuator)
    :ok
  end

  # Poll until `fun` is true (or fail after `timeout` ms) — robust to scheduling
  # jitter, unlike asserting state after a fixed sleep.
  defp wait_until(fun, timeout \\ 1500) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> true
      System.monotonic_time(:millisecond) >= deadline -> false
      true -> Process.sleep(5) && do_wait(fun, deadline)
    end
  end

  defp anc?, do: Actuator.mode() == :anc
  defp transparency?, do: Actuator.mode() == :transparency

  test "starts in transparency" do
    assert Actuator.mode() == :transparency
  end

  test "an immediate window engages ANC then returns to transparency after it ends" do
    Actuator.cover(0, 150, "DAL1")
    assert wait_until(&anc?/0)
    assert wait_until(&transparency?/0)
  end

  test "overlapping windows coalesce — ANC stays on until the latest off time" do
    Actuator.cover(0, 150, "A")
    Actuator.cover(0, 600, "B")
    assert wait_until(&anc?/0)

    # Well past A's off (150) but before B's (600) — must still be engaged.
    Process.sleep(300)
    assert anc?()

    assert wait_until(&transparency?/0)
  end

  test "non-overlapping future windows do NOT bridge — ANC drops between passes" do
    Actuator.cover(0, 100, "A")
    # B engages much later, with a clear quiet gap after A ends.
    Actuator.cover(500, 600, "B")

    assert wait_until(&anc?/0)
    # A's window ends -> back to transparency, with B still pending (armed).
    assert wait_until(&transparency?/0)
    assert wait_until(fn -> Actuator.phase() == :armed end)

    # B engages around 500ms, then ends.
    assert wait_until(&anc?/0)
    assert wait_until(&transparency?/0)
  end

  test "phase reflects idle -> armed (window scheduled) -> engaged" do
    assert Actuator.phase() == :idle

    # A future window: ANC scheduled but not yet engaged -> armed.
    Actuator.cover(300, 600, "SOON")
    assert Actuator.phase() == :armed
    assert Actuator.mode() == :transparency

    assert wait_until(fn -> Actuator.phase() == :engaged end)
    assert wait_until(fn -> Actuator.phase() == :idle end)
  end

  test "reset forces transparency immediately" do
    Actuator.cover(0, 5_000, "LONG")
    assert wait_until(&anc?/0)

    Actuator.reset()
    assert Actuator.mode() == :transparency
  end
end
