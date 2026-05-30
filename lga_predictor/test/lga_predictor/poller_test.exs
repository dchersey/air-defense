defmodule LgaPredictor.PollerTest do
  use ExUnit.Case

  alias LgaPredictor.{Actuator, Poller}
  alias LgaPredictor.FR24.Aircraft

  @home {40.728, -73.864}

  # Already over home (inside the zone at t=0) so the ANC window opens immediately.
  defp inbound do
    %Aircraft{
      callsign: "INBND",
      lat: 40.728,
      lon: -73.864,
      track_deg: 0.0,
      gspeed_kt: 100.0,
      vspeed_fpm: 0.0,
      alt_ft: 3000.0
    }
  end

  setup do
    start_supervised!(Actuator)

    fetcher = fn _state -> {:ok, [inbound()]} end

    start_supervised!(
      {Poller,
       [
         fetcher: fetcher,
         noise_zone: {:circle, @home, 1.0},
         prediction_window_seconds: 90,
         poll_interval_ms: 30,
         session_duration_ms: 10_000,
         anc_lead_seconds: 8,
         anc_tail_seconds: 12
       ]}
    )

    :ok
  end

  test "is idle until a session starts" do
    assert %{active?: false} = Poller.status()
    assert Actuator.mode() == :transparency
  end

  test "a session polls, finds the inbound aircraft, and engages ANC" do
    :ok = Poller.start_session()
    Process.sleep(80)

    status = Poller.status()
    assert status.active?
    assert status.polls >= 1
    # 1 aircraft * 6 credits, at least once
    assert status.approx_credits >= 6

    assert Actuator.mode() == :anc
  end

  test "stopping a session goes idle and returns to transparency" do
    :ok = Poller.start_session()
    Process.sleep(60)
    :ok = Poller.stop_session()

    assert %{active?: false} = Poller.status()
    assert Actuator.mode() == :transparency
  end
end
