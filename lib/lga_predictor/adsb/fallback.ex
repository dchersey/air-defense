defmodule LgaPredictor.ADSB.Fallback do
  @moduledoc "Shared, rate-limited regional cache for the airplanes.live feeder fallback."
  use GenServer

  # All zones and the classifier share a response. Never reuse success after a
  # failed refresh, and age positions while cached so freshness gates stay honest.
  @interval_ms 5000
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def positions(bounds, server \\ __MODULE__), do: GenServer.call(server, {:positions, bounds}, 15_000)

  @impl true
  def init(opts) do
    fetch = Keyword.get(opts, :fetcher, fn box ->
      LgaPredictor.ADSB.Client.positions(box, provider: :airplanes_live)
    end)
    {:ok, %{fetch: fetch, bounds: nil, result: nil, at: nil}}
  end

  @impl true
  def handle_call({:positions, box}, _from, state) do
    now = System.monotonic_time(:millisecond)
    fresh = state.at != nil and now - state.at < @interval_ms

    state = if fresh and contains?(state.bounds, box) do
      state
    else
      # Different-region requests also respect the shared request limit.
      if fresh, do: Process.sleep(@interval_ms - (now - state.at))
      {n, s, w, e} = box
      region = {n + 0.3, s - 0.3, w - 0.4, e + 0.4}
      at = System.monotonic_time(:millisecond)
      %{state | bounds: region, result: state.fetch.(region), at: at}
    end

    result = case state.result do
      {:ok, aircraft} ->
        age = (System.monotonic_time(:millisecond) - state.at) / 1000
        {n, s, w, e} = box
        {:ok, aircraft
          |> Enum.filter(&(&1.lat >= s and &1.lat <= n and &1.lon >= w and &1.lon <= e))
          |> Enum.map(&%{&1 | pos_age_s: (&1.pos_age_s || 0) + age})}
      error -> error
    end

    {:reply, result, state}
  end

  defp contains?({n, s, w, e}, {bn, bs, bw, be}), do: n >= bn and s <= bs and w <= bw and e >= be
  defp contains?(_, _), do: false
end
