defmodule LgaPredictor.RoutesTest do
  use ExUnit.Case

  alias LgaPredictor.Routes

  # adsbdb's shape: %{"response" => %{"flightroute" => %{"origin" => %{...}, ...}}}
  defp adsbdb(orig, dest) do
    %{
      "response" => %{
        "flightroute" => %{
          "origin" => %{"iata_code" => orig, "name" => "O"},
          "destination" => %{"iata_code" => dest, "name" => "D"}
        }
      }
    }
  end

  describe "parse/1" do
    test "pulls origin/destination IATA from an adsbdb body" do
      assert Routes.parse(adsbdb("YYZ", "LGA")) == {:ok, "YYZ", "LGA"}
    end

    test "unknown callsign / no flightroute -> :none" do
      assert Routes.parse(%{"response" => "unknown callsign"}) == :none
      assert Routes.parse(%{}) == :none
      assert Routes.parse(adsbdb("", "LGA")) == :none
    end
  end

  describe "get/2 (async cache)" do
    test "misses return :pending, then resolve from the cache" do
      test = self()

      fetch = fn cs ->
        send(test, {:fetched, cs})
        {:ok, "YYZ", "LGA"}
      end

      pid = start_supervised!({Routes, name: :routes_ok, fetch: fetch})

      assert Routes.get("ACA123", pid) == :pending
      assert_receive {:fetched, "ACA123"}, 1_000
      wait_until(fn -> Routes.get("ACA123", pid) == {:ok, "YYZ", "LGA"} end)
    end

    test "negative results cache as :none and aren't refetched" do
      test = self()
      fetch = fn cs -> send(test, {:fetched, cs}); :none end
      pid = start_supervised!({Routes, name: :routes_none, fetch: fetch})

      assert Routes.get("N123AB", pid) == :pending
      assert_receive {:fetched, "N123AB"}, 1_000
      wait_until(fn -> Routes.get("N123AB", pid) == :none end)

      # A second lookup is served from cache — no new fetch.
      assert Routes.get("N123AB", pid) == :none
      refute_receive {:fetched, "N123AB"}, 200
    end

    test "blank / non-binary callsigns are :none without a fetch" do
      pid = start_supervised!({Routes, name: :routes_blank, fetch: fn _ -> flunk("no fetch") end})
      assert Routes.get("", pid) == :none
      assert Routes.get(nil, pid) == :none
    end
  end

  defp wait_until(fun, tries \\ 50) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition not met in time")
      true -> Process.sleep(10); wait_until(fun, tries - 1)
    end
  end
end
