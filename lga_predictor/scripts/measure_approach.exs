# Measure the real aircraft count in the SW approach/monitor box, to validate the
# per-query credit cost for this geometry. Run: mix run scripts/measure_approach.exs
alias LgaPredictor.FR24.Client

# {north, south, west, east} — Atlantic Ave (S) / LIE (N) / BQE (W) / noise-zone meridian (E)
box = {40.738, 40.678, -73.945, -73.850}
ceiling = 4500

case Client.positions(box, :light, sandbox?: false) do
  {:ok, acs} ->
    low = Enum.filter(acs, &(is_number(&1.alt_ft) and &1.alt_ft > 0 and &1.alt_ft <= ceiling))

    IO.puts("Approach box returned #{length(acs)} aircraft (~#{length(acs) * 6} credits).")
    IO.puts("Airborne & <= #{ceiling} ft: #{length(low)}\n")

    Enum.each(low, fn a ->
      IO.puts("  #{a.callsign || a.hex}  alt=#{a.alt_ft} ft  gs=#{a.gspeed_kt} kt  track=#{a.track_deg}")
    end)

    on_ground = Enum.count(acs, &(&1.alt_ft == 0 or &1.alt_ft == "ground"))
    IO.puts("\n(on-ground/alt-0 in box: #{on_ground}; high >#{ceiling}ft: #{length(acs) - length(low) - on_ground})")

  {:error, reason} ->
    IO.inspect(reason, label: "ERROR")
end
