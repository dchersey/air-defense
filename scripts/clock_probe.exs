# Determine the REAL current time and whether 2026-05-28 is within the 14-day
# historic window. Run: mix run scripts/clock_probe.exs
alias LgaPredictor.FR24.Client

box = {40.738, 40.678, -73.945, -73.850}

now = System.os_time(:second)
now_dt = DateTime.from_unix!(now)
IO.puts("Real wall clock (UTC): #{DateTime.to_iso8601(now_dt)}  (unix #{now})")

{:ok, target} = DateTime.new(~D[2026-05-28], ~T[14:00:00], "Etc/UTC")
days_ago = (now - DateTime.to_unix(target)) / 86_400.0
IO.puts("2026-05-28 14:00Z is #{Float.round(days_ago, 1)} days before real now.\n")

try_ts = fn label, ts ->
  case Client.historic_positions(box, ts, :light, sandbox?: false) do
    {:ok, acs} -> IO.puts("OK   #{label} (#{DateTime.to_iso8601(DateTime.from_unix!(ts))}): #{length(acs)} aircraft")
    {:error, {:http_error, c, b}} -> IO.puts("#{c}  #{label}: #{inspect(b)}")
    {:error, e} -> IO.puts("ERR  #{label}: #{inspect(e)}")
  end
end

try_ts.("now - 2 days", now - 2 * 86_400)
try_ts.("now - 13 days", now - 13 * 86_400)
try_ts.("2026-05-28", DateTime.to_unix(target))
