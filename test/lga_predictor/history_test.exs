defmodule LgaPredictor.HistoryTest do
  use ExUnit.Case

  alias LgaPredictor.History

  setup do
    start_supervised!({History, max: 3})
    :ok
  end

  defp event(cs, at), do: %{callsign: cs, alt_ft: 1500, enters_in: 30, dwell: 15, at: at}

  test "records events and returns them most-recent-first" do
    History.record(event("A", 1))
    History.record(event("B", 2))

    assert [%{callsign: "B"}, %{callsign: "A"}] = History.recent(10)
  end

  test "recent/1 limits the number returned" do
    for i <- 1..3, do: History.record(event("F#{i}", i))
    assert length(History.recent(2)) == 2
  end

  test "caps stored events at :max, dropping the oldest" do
    for i <- 1..5, do: History.record(event("F#{i}", i))

    callsigns = History.recent(10) |> Enum.map(& &1.callsign)
    assert callsigns == ["F5", "F4", "F3"]
  end

  test "repeat passes keep separate numbered rows even after the first drops out" do
    History.record(event("A", 100))
    History.record(event("A", 1000))
    assert [%{pass_number: 2}, %{pass_number: 1}] = History.recent()
    History.record(event("B", 1100))
    History.record(event("C", 1200))
    History.record(event("A", 2000))
    assert hd(History.recent()).pass_number == 3
    History.record(event("A", 10_000))
    assert hd(History.recent()).pass_number == 1
  end

  test "different aircraft or callsigns and anonymous flights do not share counters" do
    History.record(Map.put(event("A", 100), :hex, "one"))
    History.record(Map.put(event("A", 200), :hex, "two"))
    History.record(Map.put(event("B", 300), :hex, "two"))
    assert Enum.all?(History.recent(), &(&1.pass_number == 1))
    History.record(event(nil, 400))
    History.record(event(nil, 500))
    assert hd(History.recent()).pass_number == 1
  end

  test "counts_per_bucket buckets events by time window" do
    # bucket size 60s: events at t=10 and t=50 share bucket 0; t=130 is bucket 2
    History.record(event("A", 10))
    History.record(event("B", 50))
    History.record(event("C", 130))

    buckets = History.counts_per_bucket(60, now: 180, buckets: 3)
    # oldest..newest buckets covering [0,60),[60,120),[120,180]
    assert buckets == [2, 0, 1]
  end
end
