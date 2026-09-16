defmodule LgaPredictor.ApproachTest do
  use ExUnit.Case, async: true

  alias LgaPredictor.Approach

  @lga {40.7772, -73.8726}
  @runways [
    %{name: "4", heading: 40},
    %{name: "22", heading: 220},
    %{name: "13", heading: 130},
    %{name: "31", heading: 310}
  ]

  defp ac(opts) do
    %{
      lat: Keyword.get(opts, :lat, 40.75),
      lon: Keyword.get(opts, :lon, -73.90),
      track_deg: Keyword.fetch!(opts, :track),
      alt_ft: Keyword.get(opts, :alt, 1200.0),
      vspeed_fpm: Keyword.get(opts, :vspeed, -800)
    }
  end

  test "pools tracks across snapshots, since one frame rarely holds enough" do
    # Three separate polls, one arrival each — the real observation pattern.
    pooled =
      [[ac(track: 33)], [ac(track: 32)], [ac(track: 38)]]
      |> Enum.flat_map(&Approach.arrival_tracks(&1, @lga))

    assert {"4", _, 3} = Approach.runway_from_tracks(pooled, @runways)
  end

  test "names the runway from the median final-approach track" do
    fleet = [ac(track: 33), ac(track: 32), ac(track: 38)]
    assert {"4", median, 3} = Approach.active_runway(fleet, @lga, @runways)
    assert_in_delta median, 34.3, 1.0
  end

  # Crab angle in a crosswind offsets the track by ~10 degrees. Runways are 90 degrees
  # apart, so this must not be able to tip the answer into the wrong bucket.
  test "crab angle does not change the answer" do
    assert {"4", _, _} = Approach.active_runway([ac(track: 28), ac(track: 30), ac(track: 29)], @lga, @runways)
    assert {"4", _, _} = Approach.active_runway([ac(track: 52), ac(track: 50), ac(track: 51)], @lga, @runways)
  end

  test "distinguishes the opposite end of the same runway" do
    assert {"22", _, _} = Approach.active_runway([ac(track: 218), ac(track: 222), ac(track: 220)], @lga, @runways)
  end

  # Departures climb out on roughly the reciprocal heading; including them would drag the
  # median toward the opposite runway end.
  test "ignores departures, however many there are" do
    arrivals = [ac(track: 35), ac(track: 37), ac(track: 36)]
    departures = for _ <- 1..6, do: ac(track: 220, vspeed: 2200)
    assert {"4", _, 3} = Approach.active_runway(arrivals ++ departures, @lga, @runways)
  end

  test "ignores traffic that is too high, too far, or not descending" do
    assert Approach.active_runway(
             [
               ac(track: 35, alt: 9000.0),
               ac(track: 35, vspeed: 0),
               ac(track: 35, lat: 41.4)
             ],
             @lga,
             @runways
           ) == nil
  end

  test "says nothing rather than guessing from too few aircraft" do
    assert Approach.active_runway([ac(track: 35)], @lga, @runways) == nil
    assert Approach.active_runway([ac(track: 35), ac(track: 36)], @lga, @runways) == nil
  end

  test "says nothing when the traffic matches no runway" do
    # 85 degrees is 45 from BOTH runway 4 and runway 13 — i.e. as far from a final
    # approach as LGA's geometry allows. Traffic transiting the area must not be
    # reported as an approach just because some runway is nearest.
    assert Approach.active_runway([ac(track: 85), ac(track: 87), ac(track: 86)], @lga, @runways) == nil
  end

  test "accepts a realistic crosswind crab but not a transit" do
    # 15 degrees off: a stiff crosswind on final, still runway 4.
    assert {"4", _, _} = Approach.active_runway([ac(track: 55), ac(track: 55), ac(track: 55)], @lga, @runways)
    # 35 degrees off: nothing lands that skewed.
    assert Approach.active_runway([ac(track: 75), ac(track: 75), ac(track: 75)], @lga, @runways) == nil
  end

  # 350 and 10 degrees average to 0 (north), not 180 (south) — a plain arithmetic mean
  # would pick the wrong runway entirely.
  test "handles the 360/0 wrap" do
    assert {"31", median, 3} =
             Approach.active_runway(
               [ac(track: 355), ac(track: 3), ac(track: 359)],
               @lga,
               [%{name: "31", heading: 359}, %{name: "13", heading: 179}]
             )

    assert median < 30 or median > 330, "expected ~0, got #{median}"
  end

  # --- Arrival route (from the whole stream, not zone crossings) ---------------------
  # `track_passes/5` follows every aircraft in the terminal area and remembers how close
  # it came to home; `route/1` lets only the ones that landed here vote.

  # Synthetic home: the centre of the test zone in poller_test, ~3 nm south of the
  # field. Same shape as the real geometry, not the real point.
  @home {40.728, -73.864}
  @now 1_000_000

  @over_home {40.728, -73.864}
  # ~1.4 nm north of the field, ~4.3 nm from home — a straight-in final that never
  # comes near the listener.
  @far_final {40.80, -73.87}
  # Hudson-ish: 8 nm west of home.
  @river {40.728, -74.03}

  # Default speed 150 kt: a jet on final. Loop-leg and transit fixtures pass their own.
  defp plane(hex, {lat, lon}, alt, vs \\ -700, opts \\ []) do
    %{hex: hex, callsign: hex, lat: lat, lon: lon, alt_ft: alt * 1.0, vspeed_fpm: vs,
      track_deg: 40.0, gspeed_kt: Keyword.get(opts, :gs, 150.0), pos_age_s: Keyword.get(opts, :pos_age, nil)}
  end

  defp seen(fleet, passes \\ %{}, at \\ @now),
    do: Approach.track_passes(passes, fleet, @lga, @home, at)

  describe "track_passes/5" do
    test "remembers each aircraft's closest pass to home and the altitude there" do
      passes = seen([plane("a", @far_final, 2000)]) |> then(&seen([plane("a", @over_home, 3600, 0)], &1))
      assert %{"a" => %{closest_nm: d, closest_alt: 3600.0}} = passes
      assert d < 0.1
    end

    test "a later, farther sighting does not overwrite the closest one" do
      passes = seen([plane("a", @over_home, 3600, 0)]) |> then(&seen([plane("a", @far_final, 1200)], &1))
      assert %{"a" => %{closest_alt: 3600.0}} = passes
    end

    test "marks an aircraft bound once seen in the core, and keeps it marked" do
      # 12 nm out, level: not yet anything.
      passes = seen([%{plane("a", @river, 5500, 0) | lon: -74.10}])
      refute passes["a"].bound
      passes = seen([plane("a", @far_final, 1200)], passes)
      assert passes["a"].bound
      passes = seen([%{plane("a", @river, 5500, 0) | lon: -74.10}], passes)
      assert passes["a"].bound, "bound is sticky"
    end

    # Departures climb out through the same airspace. Without the climb-rate gate a
    # departure passing over home at 1500 ft would look exactly like the low approach.
    test "ignores departures" do
      assert seen([plane("dep", @over_home, 1500, 2400)]) == %{}
    end

    # The loop's outbound leg — 250+ kt, descending through 3000 ft, 2-3 nm from the
    # field, heading AWAY from it — is this field's traffic and the only part of the
    # high approach this antenna ever receives. It must count.
    test "the loop leg in the terminal core is this field's traffic" do
      passes = seen([plane("loop", @far_final, 2600, -1400, gs: 266.0)])
      assert passes["loop"].bound
    end

    # A neighbouring airport's arrival descends through the same box, 7 nm out, heading
    # away from this field. Without the heading check it would vote here.
    test "a descent passing wide and heading away is not this field's traffic" do
      away = %{plane("jfk", @river, 2500, -900) | track_deg: 250.0}
      refute seen([away])["jfk"].bound
    end

    test "a descent closing on the field from outside the core is this field's traffic" do
      # 8 nm west, descending, tracking toward the field (bearing ~070).
      toward = %{plane("in", @river, 2500, -900) | track_deg: 75.0}
      assert seen([toward])["in"].bound
    end

    # readsb kept emitting a frozen position for 60+ s after losing an aircraft at 3 nm,
    # altitude still updating. A stale position is not where the aircraft is, so it
    # neither counts as bound nor moves the closest-pass record.
    test "a stale position counts for nothing" do
      passes = seen([plane("stale", @far_final, 1200, -700, pos_age: 45.0)])
      assert passes == %{}
      passes = seen([plane("ok", @over_home, 3600, 0, pos_age: 3.0)])
      assert %{"ok" => %{closest_alt: 3600.0}} = passes
    end

    # Short-final aircraft often carry no vertical rate; in the core that must not matter.
    test "no vertical rate in the core still counts" do
      assert seen([plane("nr", @far_final, 1300, 0, gs: 145.0)])["nr"].bound
    end

    test "forgets aircraft not seen within retention" do
      passes = seen([plane("a", @over_home, 3600, 0)])
      assert seen([], passes, @now + Approach.retention_seconds() + 1) == %{}
    end
  end

  # Build a fleet that has been fully observed: near home at `alt`, then in the core.
  defp landed_via(hexes, where, alt, vs \\ 0) do
    fleet1 = Enum.map(hexes, &plane(&1, where, alt, vs))
    fleet2 = Enum.map(hexes, &plane(&1, @far_final, 1200))
    seen(fleet1) |> then(&seen(fleet2, &1))
  end

  describe "route/1" do
    test "three arrivals that passed home low is the low approach" do
      assert Approach.route(landed_via(~w(a b c), @over_home, 1500, -700)) == :low_approach
    end

    test "three arrivals that passed home high is the high approach" do
      assert Approach.route(landed_via(~w(a b c), @over_home, 3600)) == :high_approach
    end

    test "three arrivals that never came near is the river approach" do
      assert Approach.route(landed_via(~w(a b c), @river, 2500)) == :river_approach
    end

    # THE CASE A MAJORITY GETS WRONG. Measured live: during a high-approach period only
    # a third of the arrivals flew the loop over home; the rest came straight in from the
    # other side. A majority would have called that "river" while seven aircraft in
    # thirteen minutes went over the listener at 3600 ft. The noisiest routing in
    # meaningful use is the answer.
    test "the noisiest route in meaningful use wins, not the majority" do
      loopers = landed_via(~w(a b c), @over_home, 3600)
      direct = landed_via(~w(d e f g h i), @river, 2500)
      assert Approach.route(Map.merge(loopers, direct)) == :high_approach
    end

    test "low outranks high" do
      low = landed_via(~w(a b c), @over_home, 1500, -700)
      high = landed_via(~w(d e f g), @over_home, 3600)
      assert Approach.route(Map.merge(low, high)) == :low_approach
    end

    test "too few arrivals is a lull, not a route" do
      assert Approach.route(landed_via(~w(a b), @over_home, 3600)) == nil
    end

    # An aircraft passing 9 nm from the field, level, bound elsewhere, says nothing about
    # this field's routing — even three of them.
    test "aircraft not bound here do not vote" do
      elsewhere = {elem(@lga, 0) - 9 / 60, elem(@lga, 1)}
      passing = seen(Enum.map(~w(a b c), &plane(&1, elsewhere, 4000, 0)))
      assert Approach.route(passing) == nil
    end

    # A helicopter that lands here after passing home at 600 ft is not an approach
    # route; nor is an aircraft whose altitude the feed omitted. Both abstain rather than
    # being counted as evidence of the quiet routing.
    test "rotorcraft and unread altitudes abstain" do
      rotor = landed_via(~w(a b c), @over_home, 600, -300)
      assert Approach.route(rotor) == nil
    end

    test "the near-home radius is wider than the ANC zone but excludes the straight-in" do
      # 2 nm off: still "over you" for a 3600 ft loop.
      two_nm = {elem(@home, 0) + 2 / 60, elem(@home, 1)}
      assert Approach.route(landed_via(~w(a b c), two_nm, 3600)) == :high_approach
      # 4.6 nm off: the straight-in final. Not over you.
      assert Approach.route(landed_via(~w(a b c), @far_final, 3600)) == :river_approach
    end
  end

  describe "overhead_band/1" do
    test "band edges" do
      assert Approach.overhead_band(999) == :rotor
      assert Approach.overhead_band(1000) == :low_approach
      assert Approach.overhead_band(2999) == :low_approach
      assert Approach.overhead_band(3000) == :high_approach
      assert Approach.overhead_band(5999) == :high_approach
      assert Approach.overhead_band(6000) == :transit
    end

    test "an absent reading has no band" do
      assert Approach.overhead_band(nil) == nil
    end
  end

  describe "arrivals/2" do
    # The path classifier counts distinct AIRCRAFT, so it needs the aircraft, not just
    # their tracks — arrival_tracks/2 is now a projection of this.
    test "returns the arriving aircraft themselves" do
      fleet = [ac(track: 40), ac(track: 40, alt: 8000), ac(track: 40, vspeed: 1800)]
      assert [%{alt_ft: 1200.0, vspeed_fpm: -800}] = Approach.arrivals(fleet, @lga)
    end
  end
end
