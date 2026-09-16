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

  # --- Arrival path (what actually happens overhead) ---------------------------------
  # `overhead_path(arrivals_near_field, overhead_altitudes)`. Both pools cover the same
  # recent window; the first is the evidence that the airport is landing at all, without
  # which an empty zone means nothing.

  describe "overhead_path/2" do
    # `overhead` is {age_seconds, altitude} per distinct aircraft that crossed the zone.
    # NOW = just observed; a large age = seen a while ago but still within retention.
    defp fresh(alts), do: Enum.map(alts, &{60, &1})

    test "a busy field with nothing crossing the zone is the river routing" do
      assert Approach.overhead_path(6, []) == :river_approach
    end

    # The whole point of counting traffic at the field: at 3am the zone is empty because
    # nobody is flying, not because the routing changed. Claiming river_approach there
    # would announce a configuration swing every single night.
    test "a quiet field with nothing crossing the zone says nothing" do
      assert Approach.overhead_path(3, []) == nil
      assert Approach.overhead_path(0, []) == nil
    end

    test "crossings on final, gear down" do
      assert Approach.overhead_path(6, fresh([1475.0, 1800.0, 1520.0])) == :low_approach
    end

    test "crossings on the long north-east loop, gear still up" do
      assert Approach.overhead_path(6, fresh([3575.0, 3600.0, 3600.0])) == :high_approach
    end

    # THE FLAPPING BUG. Overflights on a steady high approach arrived up to 18 minutes
    # apart; a single short window emptied in the gaps and reported the arrivals gone,
    # then back on the next aircraft — four times in seventy minutes while every
    # altitude sat on 3600 ft.
    #
    # The fix is that the absence branch tests the FULL retained list, not the recent
    # subset. A crossing too old to vote on the band must still veto the claim that
    # nothing is coming over.
    test "a crossing still in retention vetoes the absence claim" do
      stale = [{2000, 3600.0}, {2100, 3575.0}]
      refute Approach.overhead_path(6, stale) == :river_approach
      assert Approach.overhead_path(6, stale) == nil, "hold the state, do not guess"
    end

    test "but a sustained absence is evidence" do
      # Nothing at all: the previous crossings have aged out of retention entirely.
      assert Approach.overhead_path(6, []) == :river_approach
    end

    # The retention window is the load-bearing part: the caller must hold crossings
    # longer than the real gap between them, or the absence branch fires on a gap.
    # Measured gaps on a steady high approach reached 18 minutes.
    test "retention outlasts the observed gap between overflights" do
      assert Approach.absence_seconds() > 18 * 60
    end

    # A police helicopter over the zone is not an arrival path. Without the floor it
    # would read as a low approach — the loudest classification — on no airport traffic.
    test "rotorcraft below the arrival floor are not a path" do
      assert Approach.overhead_path(6, fresh([700.0, 450.0, 800.0])) == :river_approach
    end

    test "high transiting traffic is not a path" do
      assert Approach.overhead_path(6, fresh([11_000.0, 12_500.0])) == :river_approach
    end

    # An aircraft with no altitude reading DID cross the zone. Calling that the river
    # routing would assert the arrivals moved on the strength of missing data.
    test "an unknown altitude is not evidence either way" do
      assert Approach.overhead_path(6, fresh([nil, nil, nil])) == nil
      assert Approach.overhead_path(6, fresh([700.0, nil])) == nil
      # ...but it does not veto a picture the rest of the crossings already make clear.
      assert Approach.overhead_path(6, fresh([1500.0, 1600.0, nil])) == :low_approach
    end

    # One crossing is a go-around or an odd vector, not a pattern.
    test "a single crossing does not decide" do
      assert Approach.overhead_path(6, fresh([1500.0])) == nil
    end

    # Without the majority rule a genuinely mixed picture would flip the reported path
    # on alternate polls and fill the timeline with noise about noise.
    test "an evenly split picture says nothing rather than flapping" do
      assert Approach.overhead_path(8, fresh([1500.0, 1600.0, 3800.0, 4100.0])) == nil
    end

    test "a two-thirds majority is enough to call it" do
      assert Approach.overhead_path(8, fresh([1500.0, 1600.0, 4100.0])) == :low_approach
      assert Approach.overhead_path(8, fresh([1500.0, 3900.0, 4100.0])) == :high_approach
    end

    # Only crossings recent enough to still describe the routing get a vote.
    test "stale crossings do not vote on the current band" do
      mixed = [{60, 3600.0}, {60, 3575.0}, {2000, 1500.0}, {2000, 1600.0}]
      assert Approach.overhead_path(8, mixed) == :high_approach
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

  describe "landing_traffic/2" do
    # The gate that broke live: over 16 minutes of real LGA traffic the tight
    # final-approach filter matched ZERO aircraft, because aircraft are inside 6 nm
    # and under 3000 ft for barely a minute. The descent into the terminal area is
    # what is actually observable, so "is the field working" must not reuse the
    # runway filter.
    test "counts the descent into the terminal area, which the final gate misses" do
      descending = ac(track: 20, alt: 4500, lat: 40.90, vspeed: -900)

      assert Approach.arrivals([descending], @lga) == [], "too high and too far for a final"
      assert [_] = Approach.landing_traffic([descending], @lga)
    end

    test "climbing traffic is not evidence the field is landing" do
      assert Approach.landing_traffic([ac(track: 20, alt: 4500, lat: 40.90, vspeed: 1800)], @lga) == []
    end

    test "excludes traffic too high or too far to be bound for this field" do
      assert Approach.landing_traffic([ac(track: 20, alt: 9000, lat: 40.80, vspeed: -900)], @lga) == []
      assert Approach.landing_traffic([ac(track: 20, alt: 4500, lat: 41.10, vspeed: -900)], @lga) == []
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
