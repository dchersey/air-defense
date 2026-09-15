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
end
