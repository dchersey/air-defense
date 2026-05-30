# Find the correct altitude_ranges format (or whether it's allowed at all) and
# confirm historic works. Run: mix run scripts/param_probe.exs
alias LgaPredictor.FR24.Client

box = {40.738, 40.678, -73.945, -73.850}
{:ok, dt} = DateTime.new(~D[2026-05-28], ~T[14:00:00], "Etc/UTC")
ts = DateTime.to_unix(dt)

report = fn label, result ->
  case result do
    {:ok, acs} -> IO.puts("OK   #{label}: #{length(acs)} aircraft")
    {:error, {:http_error, code, body}} -> IO.puts("#{code}  #{label}: #{inspect(body)}")
    {:error, other} -> IO.puts("ERR  #{label}: #{inspect(other)}")
  end
end

report.("LIVE bounds only", Client.positions(box, :light, sandbox?: false))
report.("LIVE altitude_ranges=0-4500", Client.positions(box, :light, sandbox?: false, params: %{altitude_ranges: "0-4500"}))
report.("HIST bounds+timestamp only", Client.historic_positions(box, ts, :light, sandbox?: false))
report.("HIST altitude_ranges=0-4500", Client.historic_positions(box, ts, :light, sandbox?: false, params: %{altitude_ranges: "0-4500"}))
