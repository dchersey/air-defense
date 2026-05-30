# Definitively test whether FR24 altitude_ranges filtering works on this plan.
# If it does, a big box only charges for LOW aircraft and the budget is easy.
# Run: mix run scripts/measure_altfilter.exs
alias LgaPredictor.FR24.Client

box = {40.738, 40.678, -73.945, -73.850}

show = fn label, opts ->
  case Client.positions(box, :light, [sandbox?: false] ++ opts) do
    {:ok, acs} ->
      alts = acs |> Enum.map(& &1.alt_ft) |> Enum.sort_by(&(&1 || -1))
      IO.puts("#{label}: #{length(acs)} returned (~#{length(acs) * 6} cr); alts=#{inspect(alts)}")

    {:error, reason} ->
      IO.inspect(reason, label: "#{label} ERROR")
  end
end

show.("no filter", [])
show.("altitude_ranges=0-4500", params: %{altitude_ranges: "0-4500"})
show.("altitude_ranges=0-4500 (alt singular?)", params: %{"altitude_ranges" => "0-4500"})
