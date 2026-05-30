# Focused follow-up: exclude ground traffic (alt 0) to find the real airborne-low
# count that drives the credit budget. Run: mix run scripts/measure2.exs
alias LgaPredictor.FR24.Client

home = {40.728, -73.864}
{hlat, hlon} = home
box = {hlat + 0.1, hlat - 0.1, hlon - 0.13, hlon + 0.13}

probe = fn label, params ->
  case Client.positions(box, :light, sandbox?: false, params: params) do
    {:ok, acs} ->
      alts = acs |> Enum.map(& &1.alt_ft) |> Enum.sort()
      IO.puts("#{label}: #{length(acs)} returned (~#{length(acs) * 6} cr); alts=#{inspect(alts)}")

    {:error, reason} ->
      IO.inspect(reason, label: "#{label} ERROR")
  end
end

# Try excluding ground with an altitude floor. Test a couple of range syntaxes.
probe.("floor 500-4500", %{altitude_ranges: "500-4500"})
