# Verify the historic endpoint works on this plan, with ONE snapshot.
# 2026-05-28 10:00 EDT == 14:00 UTC. Run: mix run scripts/historic_probe.exs
alias LgaPredictor.FR24.Client

box = {40.738, 40.678, -73.945, -73.850}
{:ok, dt} = DateTime.new(~D[2026-05-28], ~T[14:00:00], "Etc/UTC")
ts = DateTime.to_unix(dt)

IO.puts("Historic snapshot at #{DateTime.to_iso8601(dt)} (unix #{ts}), approach box:")

case Client.historic_positions(box, ts, :light, sandbox?: false) do
  {:ok, acs} ->
    low = Enum.filter(acs, &(is_number(&1.alt_ft) and &1.alt_ft > 0 and &1.alt_ft <= 4500))
    IO.puts("  #{length(acs)} returned (~#{length(acs) * 6} cr); #{length(low)} airborne <=4500ft")

    Enum.each(low, fn a ->
      IO.puts("    #{a.callsign || a.hex}  alt=#{a.alt_ft}ft gs=#{a.gspeed_kt}kt trk=#{a.track_deg} @(#{a.lat},#{a.lon})")
    end)

  {:error, reason} ->
    IO.inspect(reason, label: "  historic ERROR")
end
