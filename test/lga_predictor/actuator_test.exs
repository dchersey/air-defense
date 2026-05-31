defmodule LgaPredictor.ActuatorTest do
  use ExUnit.Case

  alias LgaPredictor.Actuator

  setup do
    start_supervised!(Actuator)
    :ok
  end

  test "starts in transparency" do
    assert Actuator.mode() == :transparency
  end

  test "an immediate window engages ANC then returns to transparency after it ends" do
    Actuator.cover(0, 80, "DAL1")
    Process.sleep(20)
    assert Actuator.mode() == :anc

    Process.sleep(120)
    assert Actuator.mode() == :transparency
  end

  test "overlapping windows coalesce — ANC stays on until the latest off time" do
    Actuator.cover(0, 60, "A")
    Actuator.cover(0, 250, "B")
    Process.sleep(20)
    assert Actuator.mode() == :anc

    # past A's off (60) but before B's off (250) — still engaged
    Process.sleep(120)
    assert Actuator.mode() == :anc

    Process.sleep(200)
    assert Actuator.mode() == :transparency
  end

  test "phase reflects idle -> armed (window scheduled) -> engaged" do
    assert Actuator.phase() == :idle

    # A future window: ANC scheduled but not yet engaged -> armed.
    Actuator.cover(120, 300, "SOON")
    Process.sleep(20)
    assert Actuator.phase() == :armed
    assert Actuator.mode() == :transparency

    # Once it engages -> engaged.
    Process.sleep(150)
    assert Actuator.phase() == :engaged

    # After the window -> idle again.
    Process.sleep(200)
    assert Actuator.phase() == :idle
  end

  test "reset forces transparency immediately" do
    Actuator.cover(0, 5_000, "LONG")
    Process.sleep(20)
    assert Actuator.mode() == :anc

    Actuator.reset()
    assert Actuator.mode() == :transparency
  end
end
