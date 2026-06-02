defmodule LgaPredictor.PollerTest do
  use ExUnit.Case

  alias LgaPredictor.{Actuator, Poller}
  alias LgaPredictor.FR24.Aircraft

  # ANC zone: a box around home. The monitor zone is a wider box to its south.
  @anc_zone {:polygon, [{40.724, -73.870}, {40.732, -73.870}, {40.732, -73.858}, {40.724, -73.858}]}
  @monitor_box {40.738, 40.700, -73.880, -73.850}
  # A second, disjoint monitor box for the two-zoneset (independent sessions) tests.
  @z2_box {40.800, 40.780, -73.900, -73.880}

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
      max_dwell_seconds: Keyword.get(opts, :max_dwell, 30),
      engage_delta_seconds: Keyword.get(opts, :engage_delta, 0),
      release_delta_seconds: Keyword.get(opts, :release_delta, 0),
      zonesets: [
        %{
          id: "z1",
          name: "test",
          enabled: true,
          reckoning: :constant,
          accel_kt_s: 0.0,
          trigger: Keyword.get(opts, :trigger, :predict),
          # Default 0 so existing fixtures (inbound is 100 kt) still trigger.
          min_gspeed_kt: Keyword.get(opts, :min_gspeed, 0),
          poll_interval_ms: Keyword.get(opts, :zone_interval, nil),
          assume_delay_seconds: Keyword.get(opts, :assume_delay, 0.0),
          assume_duration_seconds: Keyword.get(opts, :assume_duration, 30.0),
          altitude_ceiling_ft: nil,
          monitor_zone: nil,
          monitor_box: @monitor_box,
          anc_zones: [@anc_zone]
        }
      ]
    }
  end

  # Two zonesets (arr-like z1 + a second z2 with a disjoint monitor box).
  defp config2 do
    base = config()
    [z1] = base.zonesets
    z2 = %{z1 | id: "z2", name: "two", monitor_box: @z2_box}
    %{base | zonesets: [z1, z2]}
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

  test "assume-trigger engages ANC regardless of heading (ETA is distance-based)" do
    # Already inside the ANC zone but heading AWAY — :predict would miss it; under
    # :assume the distance-based ETA is ~0 s, so ANC engages now.
    away = %{inbound() | track_deg: 350.0, callsign: "DEP", hex: "DEP1"}

    start(
      config_fun: fn -> config(trigger: :assume, assume_delay: 0.0, assume_duration: 5.0) end,
      fetcher: fn _ -> {:ok, [away]} end
    )

    :ok = Poller.start_session()
    Process.sleep(80)
    assert Actuator.mode() == :anc
  end

  test "assume-trigger times engagement by distance over groundspeed" do
    # In the monitor box but ~3 km north of the ANC zone at 100 kt -> ~60 s out.
    # Under the old fixed assume_delay=0 this engaged immediately; ETA must not.
    far = %{inbound() | lat: 40.760, callsign: "FAR", hex: "FAR1"}

    start(
      config_fun: fn -> config(trigger: :assume, assume_delay: 0.0, assume_duration: 5.0) end,
      fetcher: fn _ -> {:ok, [far]} end
    )

    :ok = Poller.start_session()
    Process.sleep(80)
    assert Actuator.mode() == :transparency
  end

  test "skips aircraft below the zoneset minimum groundspeed" do
    # Inside the ANC zone (would engage) but at 100 kt, below the 150 kt floor —
    # a helicopter / slow GA target we don't want driving ANC.
    slow = %{inbound() | gspeed_kt: 100.0, callsign: "SLOW", hex: "SLOW1"}

    start(
      config_fun: fn -> config(trigger: :assume, min_gspeed: 150) end,
      fetcher: fn _ -> {:ok, [slow]} end
    )

    :ok = Poller.start_session()
    Process.sleep(80)
    assert Actuator.mode() == :transparency
  end

  test "assume-trigger ignores ramp traffic and high flights" do
    parked = %{inbound() | alt_ft: 0.0, gspeed_kt: 0.0, hex: "R"}
    high = %{inbound() | alt_ft: 9000.0, hex: "H"}

    start(
      config_fun: fn -> config(trigger: :assume) end,
      fetcher: fn _ -> {:ok, [parked, high]} end
    )

    :ok = Poller.start_session()
    Process.sleep(80)
    assert Actuator.mode() == :transparency
  end

  test "start_session/1 activates only the named zoneset" do
    test_pid = self()

    start(
      config_fun: fn -> config2() end,
      fetcher: fn box ->
        send(test_pid, {:queried, box})
        {:ok, []}
      end
    )

    assert :ok = Poller.start_session("z1")
    assert_receive {:queried, @monitor_box}, 500
    refute_receive {:queried, @z2_box}, 100

    zonesets = Poller.status().zonesets
    assert Enum.find(zonesets, &(&1.id == "z1")).active
    refute Enum.find(zonesets, &(&1.id == "z2")).active
  end

  test "zonesets run independent sessions; stopping one leaves the other active" do
    start(config_fun: fn -> config2() end, fetcher: fn _ -> {:ok, []} end)

    :ok = Poller.start_session("z1")
    :ok = Poller.start_session("z2")
    assert Enum.all?(Poller.status().zonesets, & &1.active)

    :ok = Poller.stop_session("z1")
    zonesets = Poller.status().zonesets
    refute Enum.find(zonesets, &(&1.id == "z1")).active
    assert Enum.find(zonesets, &(&1.id == "z2")).active
    assert Poller.status().active?
  end

  test "starting an unknown zoneset errors; starting an active one errors" do
    start(config_fun: fn -> config2() end, fetcher: fn _ -> {:ok, []} end)

    assert {:error, :unknown_zoneset} = Poller.start_session("nope")
    :ok = Poller.start_session("z1")
    assert {:error, :already_active} = Poller.start_session("z1")
  end

  test "status lists all configured zonesets with their session state" do
    start(config_fun: fn -> config2() end, fetcher: fn _ -> {:ok, []} end)
    ids = Poller.status().zonesets |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == ["z1", "z2"]
  end

  test "a session paused (headphones disconnected) does not poll or spend credits" do
    test_pid = self()
    start(fetcher: fn box -> send(test_pid, {:queried, box}); {:ok, [inbound()]} end)

    :ok = Poller.set_headphones(false)
    :ok = Poller.start_session()
    Process.sleep(80)

    refute_receive {:queried, _}, 60
    assert Poller.status().approx_credits == 0
    assert Actuator.mode() == :transparency
  end

  test "reconnecting headphones resumes polling" do
    start([])
    :ok = Poller.set_headphones(false)
    :ok = Poller.start_session()
    Process.sleep(60)
    assert Actuator.mode() == :transparency

    :ok = Poller.set_headphones(true)
    Process.sleep(80)
    assert Actuator.mode() == :anc
  end

  test "status reports headphones_connected (default true) and stays active when paused" do
    start([])
    assert Poller.status().headphones_connected == true

    :ok = Poller.set_headphones(false)
    :ok = Poller.start_session()
    status = Poller.status()
    assert status.headphones_connected == false
    # session stays active (timer keeps running) even though polling is paused
    assert status.active?
  end

  test "keep-alive: on at first session start, off at last session end, once each" do
    test_pid = self()

    start(
      config_fun: fn -> config2() end,
      fetcher: fn _ -> {:ok, []} end,
      keep_alive_fun: fn which -> send(test_pid, {:keep_alive, which}) end
    )

    :ok = Poller.start_session("z1")
    assert_receive {:keep_alive, :on}

    # second concurrent zone — no extra :on
    :ok = Poller.start_session("z2")
    refute_receive {:keep_alive, :on}, 50

    # stopping one of two running zones — not off yet
    :ok = Poller.stop_session("z1")
    refute_receive {:keep_alive, :off}, 50

    # last one ends — off, once
    :ok = Poller.stop_session("z2")
    assert_receive {:keep_alive, :off}
  end

  test "keep-alive failures never block a session" do
    start(
      config_fun: fn -> config2() end,
      fetcher: fn _ -> {:ok, []} end,
      keep_alive_fun: fn _ -> raise "boom" end
    )

    assert :ok = Poller.start_session("z1")
    assert Poller.status().active?
    assert :ok = Poller.stop_session("z1")
    refute Poller.status().active?
  end

  test "engage_delta_seconds shifts the engage time (manual offset)" do
    # inbound is inside the ANC zone -> enters_in 0 -> would engage immediately;
    # a +10s engage delta pushes it out, so it's still transparency shortly after.
    start(
      config_fun: fn -> config(trigger: :assume, engage_delta: 10) end,
      fetcher: fn _ -> {:ok, [inbound()]} end
    )

    :ok = Poller.start_session()
    Process.sleep(80)
    assert Actuator.mode() == :transparency
  end

  test "after a detection the zoneset stops polling until the plane clears (lock-on)" do
    test_pid = self()

    start(
      config_fun: fn -> config(trigger: :assume) end,
      fetcher: fn box -> send(test_pid, {:queried, box}); {:ok, [inbound()]} end,
      poll_interval_ms: 30
    )

    :ok = Poller.start_session()
    # First poll detects the (inside-the-ANC-zone) plane and engages.
    assert_receive {:queried, @monitor_box}, 200
    # Locked on: with a 30ms interval we'd normally re-poll ~6x in 200ms, but the
    # zoneset is suppressed until the plane's predicted exit (seconds away).
    refute_receive {:queried, @monitor_box}, 200
    assert Actuator.mode() == :anc
  end

  test "a zoneset honors its own poll_interval_ms (faster than the global)" do
    test_pid = self()

    cfg = fn ->
      base = config2()
      [z1, z2] = base.zonesets
      %{base | zonesets: [Map.put(z1, :poll_interval_ms, 25), z2]}
    end

    # Empty fetches -> no detection/suppression, so polling continues at cadence.
    start(config_fun: cfg, fetcher: fn box -> send(test_pid, {:q, box}); {:ok, []} end, poll_interval_ms: 250)
    :ok = Poller.start_session("z1")
    :ok = Poller.start_session("z2")
    Process.sleep(300)

    counts = drain_q(%{})
    # z1 at 25ms should poll many times; z2 at the 250ms global only ~once or twice.
    assert Map.get(counts, @monitor_box, 0) >= 5
    assert Map.get(counts, @monitor_box, 0) > Map.get(counts, @z2_box, 0)
  end

  defp drain_q(acc) do
    receive do
      {:q, box} -> drain_q(Map.update(acc, box, 1, &(&1 + 1)))
    after
      0 -> acc
    end
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
