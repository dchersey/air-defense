defmodule LgaPredictor.ADSB.FallbackTest do
  use ExUnit.Case, async: true
  alias LgaPredictor.ADSB.Fallback
  alias LgaPredictor.FR24.Aircraft

  @box {40.80, 40.75, -73.92, -73.84}

  test "nearby zones share a response, trim separately, and age cached positions" do
    parent = self()
    server = start_supervised!({Fallback, name: __MODULE__, fetcher: fn region ->
      send(parent, {:fetch, region})
      {:ok, [%Aircraft{lat: 40.76, lon: -73.87, pos_age_s: 3}]}
    end})
    assert {:ok, [first]} = Fallback.positions(@box, server)
    assert_receive {:fetch, _}
    assert {:ok, []} = Fallback.positions({40.9, 40.85, -73.92, -73.84}, server)
    assert {:ok, [cached]} = Fallback.positions(@box, server)
    assert cached.pos_age_s >= first.pos_age_s
    refute_receive {:fetch, _}
  end

  test "a failed refresh replaces cached success and errors are also rate limited" do
    {:ok, mode} = Agent.start_link(fn -> :ok end)
    parent = self()
    server = start_supervised!({Fallback, name: Module.concat(__MODULE__, Failure), fetcher: fn _ ->
      send(parent, :fetch)
      case Agent.get(mode, & &1) do
        :ok -> {:ok, [%Aircraft{lat: 40.76, lon: -73.87}]}
        :error -> {:error, {:http_error, 403, %{}}}
      end
    end})
    assert {:ok, [_]} = Fallback.positions(@box, server)
    assert_receive :fetch
    Agent.update(mode, fn _ -> :error end)
    :sys.replace_state(server, &%{&1 | at: System.monotonic_time(:millisecond) - 2100})
    assert {:error, {:http_error, 403, %{}}} = Fallback.positions(@box, server)
    assert_receive :fetch
    assert {:error, {:http_error, 403, %{}}} = Fallback.positions(@box, server)
    refute_receive :fetch
  end
end
