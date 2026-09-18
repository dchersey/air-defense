defmodule LgaPredictor.RouteHistoryTest do
  use ExUnit.Case
  alias LgaPredictor.RouteHistory

  setup do
    path =
      Path.join(System.tmp_dir!(), "route_history_#{System.unique_integer([:positive])}.json")

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".tmp")
    end)

    start_supervised!({RouteHistory, path: path})
    %{path: path}
  end

  test "merges observations and calculates duration shares across route changes" do
    RouteHistory.observe(:low_approach, 100)
    RouteHistory.observe(:low_approach, 130)
    RouteHistory.observe(:high_approach, 160)
    RouteHistory.observe(:high_approach, 190)
    data = RouteHistory.snapshot(190)
    assert data.classified_seconds == 90
    assert [%{start_at: 100, end_at: 160}, %{start_at: 160, end_at: 190}] = data.intervals
    assert_in_delta Enum.at(data.shares, 0).percent, 200 / 3, 0.001
    assert_in_delta Enum.at(data.shares, 1).percent, 100 / 3, 0.001
  end

  test "does not extrapolate through outages, unknown routes, or the future" do
    RouteHistory.observe(:low_approach, 100)
    RouteHistory.observe(nil, 130)
    RouteHistory.observe(:high_approach, 160)
    RouteHistory.observe(:high_approach, 1000)
    RouteHistory.observe(:high_approach, 1030)
    data = RouteHistory.snapshot(2000)
    assert data.classified_seconds == 60
    assert [%{start_at: 100, end_at: 130}, %{start_at: 1000, end_at: 1030}] = data.intervals
  end

  test "history survives restart without bridging the unobserved interval", %{path: path} do
    RouteHistory.observe(:river_approach, 100)
    RouteHistory.observe(:river_approach, 130)
    assert RouteHistory.snapshot(130).classified_seconds == 30
    stop_supervised!(RouteHistory)
    start_supervised!({RouteHistory, path: path})
    RouteHistory.observe(:river_approach, 160)
    RouteHistory.observe(:river_approach, 190)
    assert RouteHistory.snapshot(190).classified_seconds == 60
  end

  test "clips intervals to exact rolling 30-day boundary and retains no older data" do
    RouteHistory.observe(:low_approach, 100)
    RouteHistory.observe(:low_approach, 160)
    now = 30 * 86_400 + 130
    assert [%{start_at: 130, end_at: 160}] = RouteHistory.snapshot(now).intervals
    RouteHistory.observe(:high_approach, now + 100)
    assert RouteHistory.snapshot(now + 100).intervals == []
  end

  test "empty history has zero shares and tolerates corrupt persisted JSON", %{path: path} do
    stop_supervised!(RouteHistory)
    File.write!(path, "broken")
    start_supervised!({RouteHistory, path: path})
    data = RouteHistory.snapshot(100)
    assert data.classified_seconds == 0
    assert Enum.all?(data.shares, &(&1.percent == 0))
  end
end
