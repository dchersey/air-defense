defmodule LgaPredictor.PollerTest do
  use ExUnit.Case

  alias LgaPredictor.{Actuator, Poller}
  alias LgaPredictor.FR24.Aircraft

  # ANC zone: a box around home. The monitor zone is a wider box to its south.
  @anc_zone {:polygon,
             [{40.724, -73.870}, {40.732, -73.870}, {40.732, -73.858}, {40.724, -73.858}]}
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
          type: Keyword.get(opts, :type, :arrival),
          reckoning: :constant,
          accel_kt_s: 0.0,
          trigger: Keyword.get(opts, :trigger, :predict),
          # Default 0 so existing fixtures (inbound is 100 kt) still trigger.
          min_gspeed_kt: Keyword.get(opts, :min_gspeed, 0),
          poll_interval_ms: Keyword.get(opts, :zone_interval, nil),
          # Per-zone ANC offsets; nil → fall back to the global engage/release deltas.
          engage_delta_seconds: Keyword.get(opts, :zone_engage_delta, nil),
          release_delta_seconds: Keyword.get(opts, :zone_release_delta, nil),
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
      # No route file by default: tests must not read or write the real one.
      route_path: nil,
      window_seconds: 90,
      poll_interval_ms: 30,
      session_duration_ms: 10_000
    ]

    start_supervised!({Poller, Keyword.merge(defaults, opts)})
  end

  # --- Ambient tracking (graph continues while ANC is off) --------------------------
  # The 60s timer is far too slow for a test, so drive the tick directly — that also
  # exercises the real handle_info clause rather than a test-only path.
  defp ambient_tick! do
    send(Poller, :ambient)
    Process.sleep(60)
  end

  # Route classification has its own, slower timer; drive it the same way.
  defp approach_tick! do
    send(Poller, :approach)
    Process.sleep(60)
  end

  defp low_overflight(alt) do
    %{inbound() | callsign: "AMB123", hex: "ABCDEF", alt_ft: alt}
  end

  defp start_with_history(opts) do
    start_supervised!(LgaPredictor.History)
    start(opts)
  end

  test "ambient tracking records in-zone traffic while no session is running" do
    start_with_history(fetcher: fn _ -> {:ok, [low_overflight(2000.0)]} end)
    ambient_tick!()

    assert [%{callsign: "AMB123", engaged: false}] = LgaPredictor.History.all()
    assert Actuator.mode() == :transparency, "ambient must never fire ANC"
    refute Poller.status().active?
  end

  # receiver_ok is reported only for the local provider — the other feeds have no
  # receiver of ours to be down, and their outages are feed_ok's business. The test
  # config must therefore say :local, or the flag reads nil and `refute` passes for the
  # wrong reason.
  defp local_config, do: fn -> config() |> Map.put(:provider, :local) end

  test "a receiver that stops answering is flagged even with no session running" do
    # The case that matters: nothing else is watching. The Pi's own health monitor dies
    # with the Pi, and feed_ok only means anything while a session polls.
    start_with_history(config_fun: local_config(), fetcher: fn _ -> {:error, :timeout} end)
    ambient_tick!()
    ambient_tick!()

    assert Poller.status().receiver_ok == false
    refute Poller.status().active?, "and with no session, so nothing else would notice"
  end

  # At a 5 s tick a single timed-out fetch is routine; it must not flash the antenna.
  test "one missed poll between good ones is not an outage" do
    alive = fn _ -> {:ok, [low_overflight(2000.0)]} end
    dead = fn _ -> {:error, :timeout} end
    agent = start_supervised!({Agent, fn -> alive end})

    start_with_history(config_fun: local_config(), fetcher: fn box -> Agent.get(agent, & &1).(box) end)
    ambient_tick!()
    assert Poller.status().receiver_ok == true

    Agent.update(agent, fn _ -> dead end)
    ambient_tick!()
    assert Poller.status().receiver_ok == true, "one miss is not evidence"

    Agent.update(agent, fn _ -> alive end)
    ambient_tick!()
    assert Poller.status().receiver_ok == true

    # But two in a row is.
    Agent.update(agent, fn _ -> dead end)
    ambient_tick!()
    ambient_tick!()
    assert Poller.status().receiver_ok == false
  end

  test "the receiver flag clears once it answers again" do
    alive = fn _ -> {:ok, [low_overflight(2000.0)]} end
    dead = fn _ -> {:error, :timeout} end
    agent = start_supervised!({Agent, fn -> dead end})

    start_with_history(
      config_fun: local_config(),
      fetcher: fn box -> Agent.get(agent, & &1).(box) end
    )

    ambient_tick!()
    ambient_tick!()
    assert Poller.status().receiver_ok == false

    Agent.update(agent, fn _ -> alive end)
    ambient_tick!()
    assert Poller.status().receiver_ok == true, "recovery is immediate"
  end

  test "providers with no receiver of ours report nil, not a false alarm" do
    start_with_history(config_fun: fn -> Map.put(config(), :provider, :fr24) end,
      fetcher: fn _ -> {:error, :timeout} end)
    ambient_tick!()
    ambient_tick!()
    assert Poller.status().receiver_ok == nil
  end

  # The high approach crosses the ANC polygon at 260+ kt in ~20 s. A 60 s tick caught
  # about one pass in three and the overflight counter read 0 under a running loop.
  test "ambient polls fast on a free feed and slowly on a metered one" do
    assert Poller.ambient_interval_ms(:local) <= 10_000
    assert Poller.ambient_interval_ms(:fr24) >= 60_000
    # And route classification is a separate, slower timer: it looks outside the zone.
    assert Poller.approach_interval_ms() >= 30_000
    assert Poller.approach_interval_ms() > Poller.ambient_interval_ms(:local)
  end

  test "ambient tracking is skipped on a metered provider" do
    start_with_history(
      config_fun: fn -> config() |> Map.put(:provider, :fr24) end,
      fetcher: fn _ -> {:ok, [low_overflight(2000.0)]} end
    )

    ambient_tick!()
    assert LgaPredictor.History.all() == [], "must not poll a paid feed to draw a graph"
  end

  test "an aircraft crossing the zone is recorded once, not once per ambient poll" do
    start_with_history(fetcher: fn _ -> {:ok, [low_overflight(2000.0)]} end)

    ambient_tick!()
    ambient_tick!()
    ambient_tick!()

    assert length(LgaPredictor.History.all()) == 1
  end

  # --- Arrival route marker ---------------------------------------------------------
  # Real geometry: home sits ~3 nm south of the field, inside the zone. An aircraft over
  # home on final is therefore also on short final to the field — which is exactly what
  # makes the low approach both loud and "landed here" in the same breath.
  @lga {40.7772, -73.8726}
  @home {40.728, -73.864}
  # ~1.4 nm north of the field, ~4.3 nm from home: a straight-in final that never
  # comes near the listener. Landing signature (low, descending, close to the field).
  @far_final {40.790, -73.870}

  # 150 kt: a jet on final. The landing gate is a speed gate, so fixtures that are
  # supposed to land must fly like something landing.
  defp plane(hex, {lat, lon}, alt, vs \\ -700) do
    %Aircraft{callsign: hex, hex: hex, lat: lat, lon: lon, track_deg: 40.0, gspeed_kt: 150.0, vspeed_fpm: vs, alt_ft: alt * 1.0, type: "E75L"}
  end

  defp with_home(opts \\ []) do
    fn -> config(opts) |> Map.put(:airport_coords, @lga) |> Map.put(:home_coords, @home) end
  end

  # The route is a state in status, not a row in history.
  defp route, do: Poller.status().route

  # A fleet observed across two ticks: first at `where`/`alt`, then on short final.
  # ~2.5 nm north of the field: farther from home than @far_final, so a fleet seen there
  # after @far_final is moving AWAY from home — its pass is complete and it may vote.
  @gone_away {40.815, -73.870}

  defp fly_and_land(feed, hexes, where, alt, vs \\ 0) do
    Agent.update(feed, fn _ -> Enum.map(hexes, &plane(&1, where, alt, vs)) end)
    approach_tick!()
    Agent.update(feed, fn _ -> Enum.map(hexes, &plane(&1, @far_final, 1200)) end)
    approach_tick!()
    Agent.update(feed, fn _ -> Enum.map(hexes, &plane(&1, @gone_away, 800)) end)
    approach_tick!()
  end

  # Only ever seen on the straight-in, then moving away: never came near, pass complete.
  defp straight_in(feed, hexes) do
    Agent.update(feed, fn _ -> Enum.map(hexes, &plane(&1, @far_final, 1200)) end)
    approach_tick!()
    Agent.update(feed, fn _ -> Enum.map(hexes, &plane(&1, @gone_away, 800)) end)
    approach_tick!()
  end

  defp start_route_test do
    {:ok, feed} = Agent.start_link(fn -> [] end)
    start_with_history(config_fun: with_home(), fetcher: fn _ -> {:ok, Agent.get(feed, & &1)} end)
    feed
  end

  test "arrivals that passed over home low are recorded as the low approach" do
    feed = start_route_test()
    fly_and_land(feed, ~w(a b c), @home, 1500, -700)
    assert route() == "low approach"
    assert LgaPredictor.History.all() |> Enum.all?(&(not Map.has_key?(&1, :approach))),
           "a route is not a flight-list row"
  end

  test "arrivals that passed over home high are the high approach" do
    feed = start_route_test()
    fly_and_land(feed, ~w(a b c), @home, 3600)
    assert route() == "high approach"
  end

  test "arrivals that never came near home are the river approach" do
    # Only ever seen on the straight-in final, well clear of home.
    feed = start_route_test()
    straight_in(feed, ~w(a b c))
    assert route() == "river approach"
  end

  # The live failure this guards: the high approach drifted a mile sideways, stopped
  # crossing the ANC polygon, and the marker announced the river while aircraft went
  # over the listener at 3600 ft. Route is measured against HOME, not the zone.
  test "an aircraft passing 2 nm from home is still over you" do
    feed = start_route_test()
    two_nm_off = {elem(@home, 0) + 2 / 60, elem(@home, 1)}
    fly_and_land(feed, ~w(a b c), two_nm_off, 3600)
    assert route() == "high approach"
  end

  test "the noisiest route in use wins even when most arrivals avoid home" do
    feed = start_route_test()
    # Six straight-in, three around the loop over home.
    straight_in(feed, ~w(d e f g h i))
    fly_and_land(feed, ~w(a b c), @home, 3600)
    assert route() == "high approach"
  end

  test "an unchanged route keeps its start time while the poll time advances" do
    start_supervised!({LgaPredictor.RouteHistory, path: nil})
    feed = start_route_test()
    fly_and_land(feed, ~w(a b c), @home, 3600)
    %{route: "high approach", route_since: since, route_polled_at: polled} = Poller.status()
    assert is_integer(since) and is_integer(polled)
    Process.sleep(1100)
    approach_tick!()
    %{route_since: since2, route_polled_at: polled2} = Poller.status()
    assert since2 == since, "the route did not change, so neither does its start"
    assert polled2 > polled, "but the classifier is visibly still looking"
    history = LgaPredictor.RouteHistory.snapshot()
    assert history.classified_seconds >= 1
    assert [%{route: "high_approach"}] = history.intervals,
           "unchanged classifications must extend durable history even without an ANC session"
  end

  test "a change of route records where it changed FROM" do
    feed = start_route_test()
    straight_in(feed, ~w(a b c))
    assert route() == "river approach"

    # Then three around the loop, low.
    fly_and_land(feed, ~w(x y z), @home, 1500, -700)
    assert route() == "low approach"
  end

  # --- Route persistence -------------------------------------------------------------
  defp route_file do
    f = Path.join(System.tmp_dir!(), "air-defense-route-test-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(f) end)
    f
  end

  # Every install, reboot or rebuild restarts the backend; the banner's "since" must
  # not restart with it, or a routing that began yesterday afternoon reads as today's.
  test "the route and its start survive a restart" do
    f = route_file()
    File.write!(f, Jason.encode!(%{route: "river_approach", since: 1_700_000_000}))
    start_with_history(config_fun: with_home(), fetcher: fn _ -> {:ok, []} end, route_path: f)
    assert %{route: "river approach", route_since: 1_700_000_000} = Poller.status()
  end

  test "a restart followed by the same route keeps the original start" do
    f = route_file()
    File.write!(f, Jason.encode!(%{route: "high_approach", since: 1_700_000_000}))
    {:ok, feed} = Agent.start_link(fn -> [] end)
    start_with_history(config_fun: with_home(), fetcher: fn _ -> {:ok, Agent.get(feed, & &1)} end, route_path: f)
    fly_and_land(feed, ~w(a b c), @home, 3600)
    assert %{route: "high approach", route_since: 1_700_000_000} = Poller.status()
  end

  test "a change of route is written to the file" do
    f = route_file()
    {:ok, feed} = Agent.start_link(fn -> [] end)
    start_with_history(config_fun: with_home(), fetcher: fn _ -> {:ok, Agent.get(feed, & &1)} end, route_path: f)
    fly_and_land(feed, ~w(a b c), @home, 3600)
    assert %{"route" => "high_approach", "since" => since} = f |> File.read!() |> Jason.decode!()
    assert since == Poller.status().route_since
  end

  test "a missing or corrupt route file is simply no route" do
    f = route_file()
    start_with_history(config_fun: with_home(), fetcher: fn _ -> {:ok, []} end, route_path: f)
    assert Poller.status().route == nil
    stop_supervised!(Poller)
    File.write!(f, "not json")
    start_supervised!({Poller, [config_fun: with_home(), fetcher: fn _ -> {:ok, []} end, route_path: f, window_seconds: 90, poll_interval_ms: 30, session_duration_ms: 10_000]})
    assert Poller.status().route == nil
  end

  test "a lull is not reported as a route" do
    feed = start_route_test()
    fly_and_land(feed, ~w(a b), @home, 3600)
    assert route() == nil
  end

  test "the route needs home configured, but not runways" do
    feed = start_route_test()
    # runways: [] must not silence it.
    straight_in(feed, ~w(a b c))
    assert route() == "river approach"
  end

  test "traffic under 3000 ft raises the ambient flag" do
    start_with_history(fetcher: fn _ -> {:ok, [low_overflight(2000.0)]} end)
    ambient_tick!()
    assert Poller.status().ambient, "under 3000 ft should light the idle icon"
  end

  test "a helicopter below 1000 ft is tracked but does not raise the ambient flag" do
    # Measured over this zone, everything under 1000 ft was rotorcraft or light GA,
    # while real LGA arrivals crossed at 1475-1800 ft. A police helicopter must not
    # make the icon claim you need ANC.
    start_with_history(fetcher: fn _ -> {:ok, [low_overflight(400.0)]} end)
    ambient_tick!()

    assert [%{engaged: false}] = LgaPredictor.History.all(), "still counted in the graph"
    refute Poller.status().ambient, "too low to be an airliner"
  end

  test "traffic above 3000 ft is tracked but does not raise the ambient flag" do
    start_with_history(fetcher: fn _ -> {:ok, [low_overflight(4500.0)]} end)
    ambient_tick!()

    assert [%{engaged: false}] = LgaPredictor.History.all(), "still counted in the graph"
    refute Poller.status().ambient, "but not low enough to call for ANC"
  end

  test "ambient keeps tracking while a session is active but the headphones are off" do
    start_with_history(fetcher: fn _ -> {:ok, [low_overflight(2000.0)]} end)
    # Headphones off BEFORE the session starts, so the session path never polls and the
    # only recorded event can be the ambient one.
    Poller.set_headphones(false)
    :ok = Poller.start_session()

    ambient_tick!()

    assert [%{engaged: false}] = LgaPredictor.History.all()
    assert Poller.status().active?, "the session is still running, just paused"
  end

  describe "arrival release anchor" do
    # 0.24 nm due north of the aircraft at 100 kt (0.02778 nm/s) -> ~8.6s to closest.
    defp listener_cfg(opts \\ []) do
      config()
      |> Map.put(:home_coords, Keyword.get(opts, :coords, {40.732, -73.864}))
      |> Map.put(:acoustic_decay_seconds, Keyword.get(opts, :decay, 6))
    end

    defp window(exits_in), do: %{enters_in: 0, exits_in: exits_in, dwell_seconds: exits_in}

    test "anchors on closest approach to the listener plus the acoustic decay" do
      cfg = listener_cfg()
      [zs] = cfg.zonesets
      r = Poller.arrival_release_in(inbound(), zs, cfg, window(99.0), 0.0)
      # ~8.6s to closest + 6s decay; nothing to do with the 99s dwell it was handed.
      assert_in_delta r, 14.6, 1.0
    end

    test "falls back to the geofence dwell when no listener position is set" do
      cfg = config()
      [zs] = cfg.zonesets
      assert Poller.arrival_release_in(inbound(), zs, cfg, window(99.0), 0.0) == 99.0
    end

    test "falls back when the aircraft has no usable track or groundspeed" do
      cfg = listener_cfg()
      [zs] = cfg.zonesets
      blind = %{inbound() | track_deg: nil}
      assert Poller.arrival_release_in(blind, zs, cfg, window(42.0), 0.0) == 42.0
    end

    test "latency and the manual trim still apply to the anchored path" do
      cfg = listener_cfg() |> Map.put(:release_delta_seconds, -3)
      [zs] = cfg.zonesets
      r = Poller.arrival_release_in(inbound(), zs, cfg, window(99.0), 2.0)
      assert_in_delta r, 14.6 - 2.0 - 3.0, 1.0
    end

    test "a listener already behind the aircraft releases promptly, not never" do
      # Closest approach is in the past -> negative tca; the decay is all that is left.
      cfg = listener_cfg(coords: {40.700, -73.864})
      [zs] = cfg.zonesets
      assert Poller.arrival_release_in(inbound(), zs, cfg, window(99.0), 0.0) < 6.0
    end
  end

  test "is idle until a session starts" do
    start([])
    assert %{active?: false} = Poller.status()
    assert Actuator.mode() == :transparency
  end

  test "a session queries the monitor box, predicts the ANC zone, engages ANC" do
    # Credits only accrue on a metered provider, so pick one for the credit assertion.
    start(config_fun: fn -> config() |> Map.put(:provider, :fr24) end)
    :ok = Poller.start_session()
    Process.sleep(80)

    status = Poller.status()
    assert status.active?
    assert status.polls >= 1
    assert status.approx_credits >= 6
    assert Actuator.mode() == :anc
  end

  test "a free provider costs no credits" do
    # Counting free-feed polls as credits made the month-to-date tally read ~10x FR24's
    # real billing — the credit bar cried wolf while actual usage was fine.
    start(config_fun: fn -> config() |> Map.put(:provider, :local) end)
    :ok = Poller.start_session()
    Process.sleep(80)

    status = Poller.status()
    assert status.polls >= 1, "it still polls"
    assert status.approx_credits == 0, "but a free feed spends nothing"
  end

  test "departure zone engages ANC when a flight is in the ANC zone" do
    start(config_fun: fn -> config(type: :departure) end, fetcher: fn _ -> {:ok, [inbound()]} end)
    :ok = Poller.start_session()
    Process.sleep(80)
    assert Actuator.mode() == :anc
  end

  test "departure zone does NOT engage for a fly-by alongside the zone" do
    # Same latitude band as the ANC zone but well west of it, heading north → never enters.
    byflight = %{inbound() | lon: -73.895, track_deg: 0.0}

    start(
      config_fun: fn -> config(type: :departure, latency: 0.0) end,
      fetcher: fn _ -> {:ok, [byflight]} end
    )

    :ok = Poller.start_session()
    Process.sleep(80)
    assert Actuator.mode() == :transparency
  end

  test "departure zone drops a flight that has already passed the zone (no engage)" do
    # South of the ANC zone's south edge, heading south → missed.
    past = %{inbound() | lat: 40.710, track_deg: 180.0}
    start(config_fun: fn -> config(type: :departure) end, fetcher: fn _ -> {:ok, [past]} end)
    :ok = Poller.start_session()
    Process.sleep(80)
    assert Actuator.mode() == :transparency
  end

  test "departure engage applies engage_delta (same lead as arrivals)" do
    # Flight ~0.012° south of the ANC zone's south edge (40.724), heading north at
    # 100 kt (~0.000463°/s). With a 30 s latency lead it projects INTO the zone; the
    # +10 s engage_delta cuts the lead to 20 s, so the projected point stays short —
    # no engage. Proves departures honor engage_delta the way arrivals do.
    approaching = %{inbound() | lat: 40.712, lon: -73.864, track_deg: 0.0}

    start(
      config_fun: fn -> config(type: :departure, latency: 30.0, engage_delta: 10) end,
      fetcher: fn _ -> {:ok, [approaching]} end
    )

    :ok = Poller.start_session()
    Process.sleep(80)
    assert Actuator.mode() == :transparency
  end

  test "departure with negative effective lead delays engage past entry" do
    # latency 2, engage_delta 6 → lead -4s. A plane that has only just crossed the
    # south edge should NOT engage yet (matches arrivals' enters_in == latency -
    # engage_delta = -4, i.e. engage 4 s after geometric entry).
    just_in = %{inbound() | lat: 40.7245, lon: -73.864, track_deg: 0.0}

    start(
      config_fun: fn -> config(type: :departure, latency: 2.0, engage_delta: 6) end,
      fetcher: fn _ -> {:ok, [just_in]} end
    )

    :ok = Poller.start_session()
    Process.sleep(80)
    assert Actuator.mode() == :transparency
  end

  test "departure with negative lead engages once it is that far into the zone" do
    # With the baked +6 departure bias, engage_delta 0 + latency 2 gives lead -4: a plane
    # already well inside (its position 4 s ago is still in the zone) → engage now.
    deep = %{inbound() | lat: 40.728, lon: -73.864, track_deg: 0.0}

    start(
      config_fun: fn -> config(type: :departure, latency: 2.0, engage_delta: 0) end,
      fetcher: fn _ -> {:ok, [deep]} end
    )

    :ok = Poller.start_session()
    Process.sleep(80)
    assert Actuator.mode() == :anc
  end

  test "departure leg clears when the flight vanishes from the feed (no phantom amber)" do
    # An approaching plane (amber) that then disappears from the feed must not leave a
    # lingering armed leg — the next poll with it absent sweeps it.
    approaching = %{inbound() | lat: 40.712, lon: -73.864, track_deg: 0.0}
    # The fetcher returns the plane on the first poll, then nothing (it dropped off
    # ADS-B). An Agent flips state since the fetcher runs inside the GenServer.
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    start(
      config_fun: fn -> config(type: :departure, latency: 0.0, zone_interval: 50) end,
      fetcher: fn _ ->
        n = Agent.get_and_update(calls, &{&1, &1 + 1})
        if n == 0, do: {:ok, [approaching]}, else: {:ok, []}
      end
    )

    # start_session polls once synchronously → the approaching leg exists now.
    :ok = Poller.start_session()
    assert hd(Poller.status().zonesets).phase == "armed"

    # The next poll (~50 ms) sees an empty feed → the leg is swept.
    Process.sleep(90)
    assert hd(Poller.status().zonesets).phase == "monitoring"
  end

  test "departure engages when the projected lead carries it into the zone" do
    # Same flight as above; latency 36 minus the baked +6 departure bias = 30 s lead,
    # whose projected point reaches the zone → engages (engage_delta 0).
    approaching = %{inbound() | lat: 40.712, lon: -73.864, track_deg: 0.0}

    start(
      config_fun: fn -> config(type: :departure, latency: 36.0, engage_delta: 0) end,
      fetcher: fn _ -> {:ok, [approaching]} end
    )

    :ok = Poller.start_session()
    Process.sleep(80)
    assert Actuator.mode() == :anc
  end

  test "departure approaching the zone reports armed (amber), not engaged" do
    # South of the ANC zone, heading north, closing on it but not yet in/at it
    # (latency 0 → no projection lead). Should read as inbound/armed, ANC still off.
    approaching = %{inbound() | lat: 40.712, lon: -73.864, track_deg: 0.0}

    start(
      config_fun: fn -> config(type: :departure, latency: 0.0, engage_delta: 0) end,
      fetcher: fn _ -> {:ok, [approaching]} end
    )

    :ok = Poller.start_session()
    Process.sleep(80)

    assert Actuator.mode() == :transparency
    status = Poller.status()
    zone = hd(status.zonesets)
    assert zone.phase == "armed"
    assert zone.inbound >= 1
    assert status.inbound_callsign == "INBND"
  end

  test "departure parallel fly-by does not report armed (not closing)" do
    # In the latitude band but well west, heading due north → distance to the zone
    # grows, not shrinks: it's a miss, so no amber.
    byflight = %{inbound() | lon: -73.895, track_deg: 0.0}

    start(
      config_fun: fn -> config(type: :departure, latency: 0.0) end,
      fetcher: fn _ -> {:ok, [byflight]} end
    )

    :ok = Poller.start_session()
    Process.sleep(80)
    assert hd(Poller.status().zonesets).phase == "monitoring"
  end

  test "departure overhead exposes live-tracking (no clear-by time)" do
    start(config_fun: fn -> config(type: :departure) end, fetcher: fn _ -> {:ok, [inbound()]} end)
    :ok = Poller.start_session()
    Process.sleep(80)

    status = Poller.status()
    assert Actuator.mode() == :anc
    assert status.overhead_callsign == "INBND"
    # Departures release on actual exit, not a prediction → no countdown.
    assert status.overhead_at == nil
  end

  test "arrival overhead exposes a clear-by time" do
    start([])
    :ok = Poller.start_session()
    Process.sleep(80)

    status = Poller.status()
    assert status.overhead_callsign == "INBND"
    assert is_integer(status.overhead_at)
  end

  test "a failed local receiver falls back to FR24 once, and a new session re-checks it" do
    # A failing local receiver may fall back to a configured FR24 key; report
    # which feed is actually in use.
    # The 2-arity fetcher receives the provider the poller resolved.
    {:ok, seen} = Agent.start_link(fn -> [] end)

    # Failover requires an FR24 key. Use the env fallback so this doesn't depend on
    # whatever happens to be in the developer's Keychain (and works on CI).
    System.put_env("FR24_API_KEY", "test-key")
    on_exit(fn -> System.delete_env("FR24_API_KEY") end)

    start(
      config_fun: fn -> config(trigger: :assume) |> Map.put(:provider, :local) end,
      fetcher: fn _box, provider ->
        Agent.update(seen, &[provider | &1])
        if provider == :local, do: {:error, {:http_error, 503, %{}}}, else: {:ok, []}
      end,
      poll_interval_ms: 20
    )

    assert Poller.status().provider_active == "local"

    :ok = Poller.start_session()
    Process.sleep(120)

    status = Poller.status()
    assert status.provider_active == "fr24", "failed over to FR24 after repeated receiver errors"
    assert status.provider_fallback_reason == "HTTP 503", "reports why it switched"
    assert :fr24 in Agent.get(seen, & &1), "actually fetched from the fallback"

    # A fresh session re-checks the configured provider (the receiver may have recovered).
    :ok = Poller.stop_session()
    :ok = Poller.start_session()
    assert Poller.status().provider_active == "local",
           "next session starts back on the configured provider"
  end

  test "feed_ok flips false after consecutive fetch errors and recovers on success" do
    # A test-controlled mode flag (not a poll counter — that races the timing): the
    # feed errors (provider/network down), then the test flips it healthy. feed_ok must
    # drop so the UI can flag a dead feed (and not sound the all-clear), then recover.
    {:ok, mode} = Agent.start_link(fn -> :error end)

    start(
      config_fun: fn -> config(trigger: :assume) end,
      fetcher: fn _ ->
        if Agent.get(mode, & &1) == :error, do: {:error, :timeout}, else: {:ok, []}
      end,
      poll_interval_ms: 20
    )

    assert Poller.status().feed_ok, "feed_ok is true while idle"

    :ok = Poller.start_session()
    Process.sleep(80)
    refute Poller.status().feed_ok, "feed_ok drops after repeated fetch errors"

    Agent.update(mode, fn _ -> :ok end)
    Process.sleep(80)
    assert Poller.status().feed_ok, "feed_ok recovers once polls succeed"
  end

  test "departure zone polls the monitor+ANC union (+margin)" do
    test_pid = self()

    start(
      config_fun: fn -> config(type: :departure) end,
      fetcher: fn box ->
        send(test_pid, {:queried, box})
        {:ok, []}
      end
    )

    :ok = Poller.start_session()
    # union(@monitor_box {40.738,40.700,-73.880,-73.850}, @anc_zone bbox
    # {40.732,40.724,-73.870,-73.858}) = {40.738,40.700,-73.880,-73.850}, +0.02°.
    assert_receive {:queried, {n, s, w, e}}, 500
    assert_in_delta n, 40.758, 1.0e-6
    assert_in_delta s, 40.680, 1.0e-6
    assert_in_delta w, -73.900, 1.0e-6
    assert_in_delta e, -73.830, 1.0e-6
  end

  test "departure holds ANC while overhead and records the flight only once" do
    start_supervised!(LgaPredictor.History)
    # Same in-zone flight returned every (fast) poll.
    start(
      config_fun: fn -> config(type: :departure) end,
      fetcher: fn _ -> {:ok, [inbound()]} end,
      poll_interval_ms: 20
    )

    :ok = Poller.start_session()
    # several polls, all in-zone
    Process.sleep(150)

    assert Actuator.mode() == :anc
    # Engage-and-hold: recorded once on entry, not re-recorded each poll.
    assert length(LgaPredictor.History.recent(10)) == 1
  end

  test "tracks intercepts for the UI (per-zone phase + inbound count)" do
    start([])
    :ok = Poller.start_session()
    Process.sleep(80)

    status = Poller.status()
    zone = Enum.find(status.zonesets, & &1.active)
    assert zone.inbound >= 1
    assert zone.phase in ["armed", "engaged"]
    assert Map.has_key?(status, :inbound_at)
  end

  test "the fetcher is called with a box covering the monitor zone and the ANC zone" do
    test_pid = self()

    start(
      fetcher: fn box ->
        send(test_pid, {:queried, box})
        {:ok, []}
      end
    )

    :ok = Poller.start_session()
    # The query box is the union of the monitor zone + ANC zone (+ margin) so we can
    # see a plane both approaching and inside the ANC zone.
    assert_receive {:queried, {n, s, w, e}}, 500
    {mn, ms, mw, me} = @monitor_box
    assert n >= mn and s <= ms and w <= mw and e >= me
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
    # z1's box encloses its monitor zone; z2 is never polled (no session).
    assert_receive {:queried, {n, s, w, e}}, 500
    {mn, ms, mw, me} = @monitor_box
    assert n >= mn and s <= ms and w <= mw and e >= me

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

    start(
      fetcher: fn box ->
        send(test_pid, {:queried, box})
        {:ok, [inbound()]}
      end
    )

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

  test "keep-alive: released when AirPods disconnect mid-session, re-acquired on reconnect" do
    test_pid = self()

    start(
      config_fun: fn -> config2() end,
      fetcher: fn _ -> {:ok, []} end,
      keep_alive_fun: fn which -> send(test_pid, {:keep_alive, which}) end
    )

    :ok = Poller.start_session("z1")
    assert_receive {:keep_alive, :on}

    # buds drop — release the hold (don't keep a disconnected route awake)
    :ok = Poller.set_headphones(false)
    assert_receive {:keep_alive, :off}

    # buds back — re-acquire while the session is still running
    :ok = Poller.set_headphones(true)
    assert_receive {:keep_alive, :on}

    # ending the session pops it once more, not twice
    :ok = Poller.stop_session("z1")
    assert_receive {:keep_alive, :off}
    refute_receive {:keep_alive, _}, 50
  end

  test "keep-alive: no hold acquired when a session starts with AirPods already off" do
    test_pid = self()

    start(
      config_fun: fn -> config2() end,
      fetcher: fn _ -> {:ok, []} end,
      keep_alive_fun: fn which -> send(test_pid, {:keep_alive, which}) end
    )

    :ok = Poller.set_headphones(false)
    :ok = Poller.start_session("z1")
    refute_receive {:keep_alive, :on}, 50

    # connecting now acquires it
    :ok = Poller.set_headphones(true)
    assert_receive {:keep_alive, :on}
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

  test "arrival approaching the ANC zone arms (amber) but does not engage until it enters" do
    # ~1 km south of the ANC zone, heading north at 100 kt → within the ETA ramp and
    # closing, but not yet in/at the zone. Engage is driven by ACTUAL entry, so ANC
    # stays off and the zone reads "armed".
    approaching = %{inbound() | lat: 40.715, lon: -73.864, track_deg: 0.0}

    start(
      config_fun: fn -> config(trigger: :assume) end,
      fetcher: fn _ -> {:ok, [approaching]} end
    )

    :ok = Poller.start_session()
    Process.sleep(80)

    assert Actuator.mode() == :transparency
    assert hd(Poller.status().zonesets).phase == "armed"
  end

  test "arrival honors a per-zone engage delta (engages earlier than the global)" do
    # Same ~1 km-south approaching plane that the test above leaves merely armed, but
    # this zone carries its own engage_delta of -30 s → a 30 s forward lead whose
    # dead-reckoned point lands inside the ANC zone, so ANC engages now even though the
    # plane hasn't physically crossed the boundary. Proves a per-zone offset overrides
    # the global one (0) for arrivals.
    approaching = %{inbound() | lat: 40.715, lon: -73.864, track_deg: 0.0}

    start(
      config_fun: fn -> config(trigger: :assume, zone_engage_delta: -30) end,
      fetcher: fn _ -> {:ok, [approaching]} end
    )

    :ok = Poller.start_session()
    Process.sleep(80)

    assert Actuator.mode() == :anc
  end

  test "arrival stays armed across the monitor→ANC gap (no green flicker once tracking)" do
    # First poll: ~1 km south and closing → arms (amber). Later polls: the plane has
    # advanced into the gap just short of the ANC zone, where a fresh approaching?
    # check fails (projecting 30 s ahead overshoots the zone, so the look-ahead point
    # is FARTHER from it) — yet the plane is neither in the zone nor a miss. It must
    # STAY armed rather than flicker back to "monitoring" (green). An Agent flips the
    # fixture since the fetcher runs inside the GenServer; the flight key is unchanged
    # so the leg isn't swept.
    far = %{inbound() | lat: 40.715, lon: -73.864, track_deg: 0.0}
    gap = %{inbound() | lat: 40.7235, lon: -73.864, track_deg: 0.0}
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    start(
      config_fun: fn -> config(trigger: :assume) end,
      fetcher: fn _ ->
        n = Agent.get_and_update(calls, &{&1, &1 + 1})
        {:ok, [if(n == 0, do: far, else: gap)]}
      end
    )

    :ok = Poller.start_session()
    Process.sleep(120)

    assert Actuator.mode() == :transparency
    assert hd(Poller.status().zonesets).phase == "armed"
  end

  test "arrival beyond the ETA ramp is not yet armed (still monitoring)" do
    # ~7 km south of the ANC zone at 100 kt → ETA well past the ramp horizon, so we
    # stay on the slow monitor cadence with no intercept leg and ANC off.
    far = %{inbound() | lat: 40.660, lon: -73.864, track_deg: 0.0}

    start(
      config_fun: fn -> config(trigger: :assume) end,
      fetcher: fn _ -> {:ok, [far]} end
    )

    :ok = Poller.start_session()
    Process.sleep(80)

    assert Actuator.mode() == :transparency
    assert hd(Poller.status().zonesets).phase == "monitoring"
  end

  # A flight just inside the monitor box, ~2.6 km south of the ANC zone at 100 kt → ETA
  # ~50 s. That straddles the two arming horizons: past the metered one (40 s), well
  # inside the free one (90 s). Arming early costs nothing on a local receiver and gives
  # the ramp far more samples to catch a speed or vector change before the engage; on a
  # metered feed each of those polls is money, so we arm late and lean on the ETA.
  defp fifty_seconds_out, do: %{inbound() | lat: 40.701, lon: -73.864, track_deg: 0.0}

  test "an arrival ~50 s out arms early on a free feed (90 s horizon)" do
    start(
      config_fun: fn -> config(trigger: :assume) |> Map.put(:provider, :local) end,
      fetcher: fn _ -> {:ok, [fifty_seconds_out()]} end
    )

    :ok = Poller.start_session()
    Process.sleep(80)

    assert hd(Poller.status().zonesets).phase == "armed"
    assert Actuator.mode() == :transparency, "armed is not engaged — ANC stays off"
  end

  test "the same arrival stays monitoring on a metered feed (40 s horizon)" do
    start(
      config_fun: fn -> config(trigger: :assume) |> Map.put(:provider, :fr24) end,
      fetcher: fn _ -> {:ok, [fifty_seconds_out()]} end
    )

    :ok = Poller.start_session()
    Process.sleep(80)

    assert hd(Poller.status().zonesets).phase == "monitoring"
    assert Actuator.mode() == :transparency
  end

  test "after a detection the zoneset stops polling until the plane clears (lock-on)" do
    test_pid = self()

    start(
      config_fun: fn -> config(trigger: :assume) end,
      fetcher: fn box ->
        send(test_pid, {:queried, box})
        {:ok, [inbound()]}
      end,
      poll_interval_ms: 30
    )

    :ok = Poller.start_session()
    # First poll detects the (inside-the-ANC-zone) plane and engages.
    assert_receive {:queried, box}, 200
    # Locked on: with a 30ms interval we'd normally re-poll ~6x in 200ms, but the
    # zoneset is suppressed until the plane's predicted exit (seconds away).
    refute_receive {:queried, ^box}, 200
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
    start(
      config_fun: cfg,
      fetcher: fn box ->
        send(test_pid, {:q, box})
        {:ok, []}
      end,
      poll_interval_ms: 250
    )

    :ok = Poller.start_session("z1")
    :ok = Poller.start_session("z2")
    Process.sleep(300)

    counts = drain_q(%{})
    # Two distinct query boxes (one per zoneset). z1 at 25ms should poll many times;
    # z2 at the 250ms global only ~once or twice.
    assert map_size(counts) == 2
    [hi, lo] = counts |> Map.values() |> Enum.sort(:desc)
    assert hi >= 5
    assert hi > lo
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
