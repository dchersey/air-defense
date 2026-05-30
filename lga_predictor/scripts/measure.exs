# One-off density measurement to inform the credit budget.
# Run: mix run scripts/measure.exs
#
# Needs FR24_SANDBOX_KEY (free smoke test) and FR24_API_KEY (real snapshot, spends credits).

alias LgaPredictor.FR24.Client

# ~±0.1 deg box around home (40.728, -73.864): roughly 22 km N-S x 17 km E-W.
home = {40.728, -73.864}
{hlat, hlon} = home
box = {hlat + 0.1, hlat - 0.1, hlon - 0.13, hlon + 0.13}
ceiling_ft = 4500

IO.puts("Box (N,S,W,E) = #{Client.bounds_param(box)}\n")

# --- 1. Sandbox smoke test (free, canned data) -------------------------------
IO.puts("== Sandbox smoke test (free) ==")

case Client.positions(box, :light, sandbox?: true) do
  {:ok, acs} ->
    IO.puts("  OK: parsed #{length(acs)} aircraft from sandbox")
    if first = List.first(acs), do: IO.inspect(first, label: "  sample")

  {:error, reason} ->
    IO.inspect(reason, label: "  sandbox ERROR")
end

# --- 2. Real production snapshot (spends credits) ----------------------------
IO.puts("\n== Production snapshot (spends credits) ==")

snapshot = fn label, opts ->
  case Client.positions(box, :light, [sandbox?: false] ++ opts) do
    {:ok, acs} ->
      alts = acs |> Enum.map(& &1.alt_ft) |> Enum.sort()
      low = Enum.count(acs, &(&1.alt_ft && &1.alt_ft <= ceiling_ft))

      IO.puts("  #{label}: #{length(acs)} returned (~#{length(acs) * 6} credits), " <>
                "#{low} at/below #{ceiling_ft} ft")
      IO.puts("    altitudes: #{inspect(alts)}")

    {:error, reason} ->
      IO.inspect(reason, label: "  #{label} ERROR")
  end
end

snapshot.("all altitudes in box", [])
snapshot.("low only (altitude_ranges=0-5000)", params: %{altitude_ranges: "0-5000"})
