defmodule LgaPredictor.RoutesTest do
  use ExUnit.Case

  alias LgaPredictor.Routes

  defp leg(orig, dest, off, on) do
    %{
      "actual_off" => off,
      "actual_on" => on,
      "origin" => %{"code_iata" => orig},
      "destination" => %{"code_iata" => dest}
    }
  end

  describe "select_route/1 (leg selection)" do
    test "prefers the airborne leg (departed, not yet landed)" do
      body = %{
        "flights" => [
          leg("ATL", "LGA", nil, nil),                          # future scheduled
          leg("ATL", "LGA", "2026-06-03T17:52:40Z", nil),       # airborne now ← pick
          leg("ATL", "LGA", "2026-06-02T18:17:31Z", "2026-06-02T19:54:00Z")  # landed
        ]
      }

      assert Routes.select_route(body) == {:ok, "ATL", "LGA"}
    end

    test "falls back to the most-recently-departed leg when none airborne" do
      body = %{
        "flights" => [
          leg("PHX", "MDW", "2026-06-03T12:00:00Z", "2026-06-03T14:00:00Z"),
          leg("MDW", "LGA", "2026-06-03T15:00:00Z", "2026-06-03T17:00:00Z")  # latest ← pick
        ]
      }

      assert Routes.select_route(body) == {:ok, "MDW", "LGA"}
    end

    test "no departed legs / no flights / bad body -> :none" do
      assert Routes.select_route(%{"flights" => [leg("A", "B", nil, nil)]}) == :none
      assert Routes.select_route(%{"flights" => []}) == :none
      assert Routes.select_route(%{}) == :none
    end
  end

  describe "get/2 (async cache + cap)" do
    test "misses return :pending, then resolve from the cache" do
      test = self()
      fetch = fn cs -> send(test, {:fetched, cs}); {:ok, "YYZ", "LGA"} end

      pid =
        start_supervised!(
          {Routes, name: :r_ok, fetch: fetch, has_key: true, cap: 9, counter: {"x", 0}}
        )

      assert Routes.get("JZA466", pid) == :pending
      assert_receive {:fetched, "JZA466"}, 1_000
      wait_until(fn -> Routes.get("JZA466", pid) == {:ok, "YYZ", "LGA"} end)
    end

    test "negative results cache as :none and aren't refetched" do
      test = self()
      fetch = fn cs -> send(test, {:fetched, cs}); :none end
      pid = start_supervised!({Routes, name: :r_none, fetch: fetch, has_key: true, cap: 9, counter: {"x", 0}})

      assert Routes.get("N123AB", pid) == :pending
      assert_receive {:fetched, "N123AB"}, 1_000
      wait_until(fn -> Routes.get("N123AB", pid) == :none end)
      assert Routes.get("N123AB", pid) == :none
      refute_receive {:fetched, "N123AB"}, 200
    end

    test "transient errors retry after the TTL instead of caching :none for the month" do
      test = self()
      {:ok, clock} = Agent.start_link(fn -> 0 end)
      {:ok, mode} = Agent.start_link(fn -> :error end)

      fetch = fn cs ->
        send(test, {:fetched, cs})
        if Agent.get(mode, & &1) == :ok, do: {:ok, "SFO", "LGA"}, else: :error
      end

      pid =
        start_supervised!(
          {Routes,
           name: :r_err,
           fetch: fetch,
           has_key: true,
           cap: 9,
           counter: {"x", 0},
           now_ms: fn -> Agent.get(clock, & &1) end}
        )

      # A transient failure negative-caches (shows :none) but is NOT a permanent miss...
      assert Routes.get("UAL5", pid) == :pending
      assert_receive {:fetched, "UAL5"}, 1_000
      wait_until(fn -> Routes.get("UAL5", pid) == :none end)

      # ...within the TTL it stays :none without refetching...
      assert Routes.get("UAL5", pid) == :none
      refute_receive {:fetched, "UAL5"}, 200

      # ...and once the TTL lapses and upstream recovers, it retries and resolves.
      Agent.update(mode, fn _ -> :ok end)
      Agent.update(clock, fn _ -> 300_001 end)
      assert Routes.get("UAL5", pid) == :pending
      assert_receive {:fetched, "UAL5"}, 1_000
      wait_until(fn -> Routes.get("UAL5", pid) == {:ok, "SFO", "LGA"} end)
    end

    test "reload_key clears negative-cached errors so a re-pasted key recovers at once" do
      System.put_env("AEROAPI_KEY", "test-key")
      on_exit(fn -> System.delete_env("AEROAPI_KEY") end)

      test = self()
      fetch = fn cs -> send(test, {:fetched, cs}); :error end
      pid = start_supervised!({Routes, name: :r_reload, fetch: fetch, has_key: true, cap: 9, counter: {"x", 0}})

      assert Routes.get("DAL9", pid) == :pending
      assert_receive {:fetched, "DAL9"}, 1_000
      wait_until(fn -> Routes.get("DAL9", pid) == :none end)

      # Re-pasting the key reloads: the error entry is purged so it refetches immediately
      # rather than reading "private" until the TTL lapses.
      GenServer.cast(pid, :reload_key)
      assert Routes.get("DAL9", pid) == :pending
      assert_receive {:fetched, "DAL9"}, 1_000
    end

    test "no key -> :none without fetching" do
      pid = start_supervised!({Routes, name: :r_nokey, fetch: fn _ -> flunk("no fetch") end, has_key: false, counter: {"x", 0}})
      assert Routes.get("AAL1", pid) == :none
    end

    test "over the monthly cap -> :none without fetching" do
      pid = start_supervised!({Routes, name: :r_cap, fetch: fn _ -> flunk("no fetch") end, has_key: true, cap: 0, counter: {"x", 0}})
      assert Routes.get("AAL1", pid) == :none
    end

    test "blank / non-binary callsigns are :none" do
      pid = start_supervised!({Routes, name: :r_blank, fetch: fn _ -> flunk("no fetch") end, has_key: true, counter: {"x", 0}})
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
