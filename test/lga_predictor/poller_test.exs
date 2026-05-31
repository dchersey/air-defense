defmodule LgaPredictor.PollerTest do
  use ExUnit.Case

  alias LgaPredictor.{Actuator, Poller}
  alias LgaPredictor.FR24.Aircraft

  @home {40.728, -73.864}
  # ANC zone: a box around home. The monitor zone is a wider box to its south.
  @anc_zone {:polygon, [{40.724, -73.870}, {40.732, -73.870}, {40.732, -73.858}, {40.724, -73.858}]}
  @monitor_box {40.738, 40.700, -73.880, -73.850}

  # A flight already over home (inside the ANC zone at t=0) so ANC engages now.
  defp inbound do
    %Aircraft{
      callsign: "INBND",
      hex: "ABC123",
      lat: 40.728,
      lon: -73.864,
      track_deg: 0.0,
      gspeed_kt: 100.0,
      vspeed_fpm: 0.0,
      alt_ft: 3000.0
    }
  end

  # One enabled zoneset, engine-shaped (as ConfigStore.get would return).
  defp config(opts \\ []) do
    %{
      global_ceiling_ft: Keyword.get(opts, :ceiling, 6000),
      anc_latency_seconds: Keyword.get(opts, :latency, 0.0),
      zonesets: [
        %{
          id: "z1",
          name: "test",
          enabled: true,
          reckoning: :constant,
          accel_kt_s: 0.0,
          altitude_ceiling_ft: nil,
          monitor_zone: nil,
          monitor_box: @monitor_box,
          anc_zones: [@anc_zone]
        }
      ]
    }
  end

  defp start(opts) do
    start_supervised!(Actuator)
    # fetcher gets the query box; returns aircraft. config_fun returns config map.
    defaults = [
      fetcher: fn _box -> {:ok, [inbound()]} end,
      config_fun: fn -> config() end,
      window_seconds: 90,
      poll_interval_ms: 30,
      session_duration_ms: 10_000
    ]

    start_supervised!({Poller, Keyword.merge(defaults, opts)})
  end

  test "is idle until a session starts" do
    start([])
    assert %{active?: false} = Poller.status()
    assert Actuator.mode() == :transparency
  end

  test "a session queries the monitor box, predicts the ANC zone, engages ANC" do
    start([])
    :ok = Poller.start_session()
    Process.sleep(80)

    status = Poller.status()
    assert status.active?
    assert status.polls >= 1
    assert status.approx_credits >= 6
    assert Actuator.mode() == :anc
  end

  test "the fetcher is called with the zoneset's monitor box" do
    test_pid = self()
    start(fetcher: fn box -> send(test_pid, {:queried, box}); {:ok, []} end)
    :ok = Poller.start_session()
    assert_receive {:queried, @monitor_box}, 500
  end

  test "ramp traffic (alt 0 / gs 0) is ignored" do
    parked = %{inbound() | alt_ft: 0.0, gspeed_kt: 0.0, callsign: "RAMP", hex: "RAMP1"}
    start(fetcher: fn _ -> {:ok, [parked]} end)
    :ok = Poller.start_session()
    Process.sleep(80)
    assert Actuator.mode() == :transparency
  end

  test "flights above the effective ceiling are ignored" do
    start(config_fun: fn -> config(ceiling: 2000) end, fetcher: fn _ -> {:ok, [inbound()]} end)
    :ok = Poller.start_session()
    Process.sleep(80)
    # inbound is at 3000 ft, ceiling 2000 -> ignored
    assert Actuator.mode() == :transparency
  end

  test "stopping a session goes idle and returns to transparency" do
    start([])
    :ok = Poller.start_session()
    Process.sleep(60)
    :ok = Poller.stop_session()

    assert %{active?: false} = Poller.status()
    assert Actuator.mode() == :transparency
  end
end
