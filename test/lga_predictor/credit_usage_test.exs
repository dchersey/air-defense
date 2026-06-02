defmodule LgaPredictor.CreditUsageTest do
  use ExUnit.Case

  alias LgaPredictor.CreditUsage

  defp wait_until(fun, timeout \\ 1000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Enum.reduce_while(Stream.cycle([:_]), nil, fn _, _ ->
      cond do
        fun.() -> {:halt, true}
        System.monotonic_time(:millisecond) >= deadline -> {:halt, false}
        true -> Process.sleep(5) && {:cont, nil}
      end
    end)
  end

  test "caches the injected usage total" do
    name = :"cu_#{System.unique_integer([:positive])}"
    start_supervised!({CreditUsage, name: name, refresh_ms: 999_999, fetcher: fn -> {:ok, 1674} end})
    assert wait_until(fn -> CreditUsage.used(name) == 1674 end)
  end

  test "keeps the last value on a fetch error" do
    # First fetch succeeds; a later refresh erroring shouldn't blank it.
    {:ok, agent} = Agent.start_link(fn -> [{:ok, 100}, {:error, :rate_limited}] end)

    fetcher = fn ->
      Agent.get_and_update(agent, fn
        [h | t] -> {h, t}
        [] -> {{:error, :empty}, []}
      end)
    end

    name2 = :"cu_#{System.unique_integer([:positive])}"
    start_supervised!({CreditUsage, name: name2, refresh_ms: 20, fetcher: fetcher})
    assert wait_until(fn -> CreditUsage.used(name2) == 100 end)
    # next refresh errors -> value stays 100
    Process.sleep(60)
    assert CreditUsage.used(name2) == 100
  end
end
