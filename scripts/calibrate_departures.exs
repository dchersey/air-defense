# Live calibration capture for the LGA departure arc. Polls a wide box over the
# arc every ~12s and appends every aircraft observation to a CSV so we can later
# reconstruct trajectories, measure acceleration, and time Roosevelt->108th St.
#
#   POLLS=20 mix run scripts/calibrate_departures.exs   # ~4 min @ 12s
# Output: /tmp/dep_calib.csv  (epoch,callsign,hex,lat,lon,alt_ft,gspeed_kt,track,vspeed)
alias LgaPredictor.FR24.Client

# Generous departure-arc box: LGA/Astoria (N) down through Jackson Heights/
# Elmhurst/Corona to ~108th St (E). N,S,W,E
box = {40.772, 40.730, -73.912, -73.845}
polls = String.to_integer(System.get_env("POLLS", "20"))
interval_ms = String.to_integer(System.get_env("INTERVAL_MS", "12000"))
path = "/tmp/dep_calib.csv"

File.write!(path, "epoch,callsign,hex,lat,lon,alt_ft,gspeed_kt,track,vspeed\n")
IO.puts("Capturing #{polls} polls @ #{interval_ms}ms over #{Client.bounds_param(box)} -> #{path}")

Enum.each(1..polls, fn n ->
  case Client.positions(box, :light, sandbox?: false) do
    {:ok, acs} ->
      t = System.os_time(:second)
      rows =
        Enum.map(acs, fn a ->
          Enum.join([t, a.callsign || "", a.hex || "", a.lat, a.lon, a.alt_ft, a.gspeed_kt, a.track_deg, a.vspeed_fpm || ""], ",")
        end)
      if rows != [], do: File.write!(path, Enum.join(rows, "\n") <> "\n", [:append])
      IO.puts("poll #{n}/#{polls}: #{length(acs)} aircraft (~#{length(acs)*6} cr)")

    {:error, r} ->
      IO.puts("poll #{n}: error #{inspect(r)}")
  end

  if n < polls, do: Process.sleep(interval_ms)
end)

IO.puts("done -> #{path}")
