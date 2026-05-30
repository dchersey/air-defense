# Inspect the RAW historic response to see why the backtest got 0 aircraft.
# Run: mix run scripts/raw_historic.exs
key = System.fetch_env!("FR24_API_KEY")
box = "40.738,40.678,-73.945,-73.85"

headers = [
  {"Accept", "application/json"},
  {"Accept-Version", "v1"},
  {"Authorization", "Bearer " <> key}
]

now = System.os_time(:second)
ts_rel = now - 2 * 86_400
{:ok, dt} = DateTime.new(~D[2026-05-28], ~T[14:00:00], "Etc/UTC")
ts_abs = DateTime.to_unix(dt)

probe = fn label, ts ->
  url = "https://fr24api.flightradar24.com/api/historic/flight-positions/light"
  resp = Req.get!(url, params: %{bounds: box, timestamp: ts}, headers: headers)
  data = is_map(resp.body) && Map.get(resp.body, "data")
  count = if is_list(data), do: length(data), else: "n/a"

  IO.puts("#{label} ts=#{ts} (#{DateTime.to_iso8601(DateTime.from_unix!(ts))}) -> HTTP #{resp.status}, data count=#{count}")
  IO.puts("  body keys: #{inspect(if is_map(resp.body), do: Map.keys(resp.body), else: resp.body)}")
  IO.puts("  body head: #{inspect(resp.body) |> String.slice(0, 300)}")
end

probe.("relative now-2d", ts_rel)
probe.("absolute 2026-05-28T14Z", ts_abs)
