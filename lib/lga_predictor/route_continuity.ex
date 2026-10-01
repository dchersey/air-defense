defmodule LgaPredictor.RouteContinuity do
  @moduledoc "Carries established routes through short, observed gaps without bridging outages."
  @gap 1200
  def new,
    do: %{route: nil, support_at: nil, last_arrival_at: nil, started_at: nil, observed_at: nil}

  def observe(state, candidate, evidence, now) do
    # An outage or restart cannot establish an observed quiet interval.
    state = if state.observed_at && now - state.observed_at <= 90, do: state, else: new()

    state = %{
      state
      | started_at: state.started_at || now,
        observed_at: now,
        last_arrival_at: latest(state.last_arrival_at, evidence.last_arrival_at)
    }

    route = candidate || state.route

    support =
      evidence.votes
      |> Enum.filter(&(&1.route == route))
      |> Enum.map(& &1.at)
      |> Enum.max(fn -> nil end)

    support =
      if candidate && candidate != state.route,
        do: support,
        else: latest(support, state.support_at)

    conflict? =
      Enum.any?(evidence.votes, &(&1.route != route and (is_nil(support) or &1.at > support)))

    last_arrival = max(state.last_arrival_at || state.started_at, state.started_at)

    result =
      cond do
        candidate != nil -> candidate
        now - last_arrival >= @gap -> :no_route_detected
        route != nil and support != nil and now - support < @gap and not conflict? -> route
        true -> nil
      end

    next =
      if result == :no_route_detected,
        do: %{state | route: nil, support_at: nil},
        else: %{state | route: route, support_at: support}

    {result, next}
  end

  defp latest(nil, b), do: b
  defp latest(a, nil), do: a
  defp latest(a, b), do: max(a, b)
end
