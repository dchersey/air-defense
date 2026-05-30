# Does a tight box around home (away from LGA's ramp ~5.5 km NNW) shed the
# ground traffic and shrink per-call cost? Run: mix run scripts/measure3.exs
alias LgaPredictor.FR24.Client

home = {40.728, -73.864}
{hlat, hlon} = home

boxes = [
  {"~3km box", {hlat + 0.014, hlat - 0.014, hlon - 0.018, hlon + 0.018}},
  {"~6km box", {hlat + 0.027, hlat - 0.027, hlon - 0.036, hlon + 0.036}}
]

for {label, box} <- boxes do
  case Client.positions(box, :light, sandbox?: false) do
    {:ok, acs} ->
      alts = acs |> Enum.map(& &1.alt_ft) |> Enum.sort()
      airborne = Enum.reject(alts, &(&1 == 0))
      IO.puts("#{label} [#{Client.bounds_param(box)}]: #{length(acs)} returned " <>
                "(~#{length(acs) * 6} cr), #{length(airborne)} airborne; alts=#{inspect(alts)}")

    {:error, reason} ->
      IO.inspect(reason, label: "#{label} ERROR")
  end
end
