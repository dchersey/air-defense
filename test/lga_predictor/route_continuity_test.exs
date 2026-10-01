defmodule LgaPredictor.RouteContinuityTest do
  use ExUnit.Case, async: true
  alias LgaPredictor.RouteContinuity, as: C
  defp evidence(route, at), do: %{last_arrival_at: at, votes: [%{route: route, at: at}]}
  defp empty, do: %{last_arrival_at: nil, votes: []}

  test "bridges short gaps but expires support without perpetually refreshing old votes" do
    {r, s} = C.observe(C.new(), :river_approach, evidence(:river_approach, 0), 0)
    assert r == :river_approach

    s =
      Enum.reduce(30..1170//30, s, fn at, state ->
        {route, next} = C.observe(state, nil, evidence(:river_approach, 0), at)
        assert route == :river_approach
        next
      end)

    assert {:no_route_detected, _} = C.observe(s, nil, empty(), 1200)
  end

  test "one new corroborating arrival maintains an established route without another three" do
    {_, s} = C.observe(C.new(), :river_approach, evidence(:river_approach, 0), 0)
    s = Enum.reduce(30..1170//30, s, fn at, st -> elem(C.observe(st, nil, empty(), at), 1) end)
    {route, s} = C.observe(s, nil, evidence(:river_approach, 1190), 1200)
    assert route == :river_approach
    assert {:river_approach, _} = C.observe(s, nil, empty(), 1230)
  end

  test "contradictory newer evidence stops carry and a confirmed change wins" do
    {_, s} = C.observe(C.new(), :river_approach, evidence(:river_approach, 0), 0)
    assert {nil, _} = C.observe(s, nil, evidence(:low_approach, 30), 30)
    assert {:low_approach, _} = C.observe(s, :low_approach, evidence(:low_approach, 30), 30)
  end

  test "outages do not carry routes or establish observed quiet time" do
    {_, s} = C.observe(C.new(), :river_approach, evidence(:river_approach, 0), 0)
    assert {nil, s} = C.observe(s, nil, empty(), 1300)
    assert s.started_at == 1300
    assert {nil, _} = C.observe(s, nil, empty(), 1330)
  end

  test "old arrival evidence after an outage cannot shorten the observed quiet window" do
    {nil, s} = C.observe(C.new(), nil, %{votes: [], last_arrival_at: 100}, 1200)
    assert {nil, _} = C.observe(s, nil, empty(), 1230)
  end

  test "unclassified arrivals differ from an observed twenty-minute absence" do
    s =
      Enum.reduce(0..1170//30, C.new(), fn at, st ->
        {nil, next} = C.observe(st, nil, empty(), at)
        next
      end)

    assert {:no_route_detected, _} = C.observe(s, nil, empty(), 1200)
    assert {nil, _} = C.observe(s, nil, %{votes: [], last_arrival_at: 1190}, 1200)
  end
end
