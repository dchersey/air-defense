defmodule LgaPredictor.RouteHistory do
  @moduledoc """
  Durable classified-route intervals, independent of ANC sessions. Only adjacent
  observations (at most 90 seconds apart) establish coverage. Restarts, outages,
  and undetermined classifications leave gaps rather than extending an old route.
  Percentages describe classified time, not aircraft counts.
  """
  use GenServer
  require Logger

  @routes ~w(low_approach high_approach river_approach)
  @window 30 * 86_400
  defp default_path do
    Path.join([
      System.user_home() || ".",
      "Library",
      "Application Support",
      "air-defense",
      "route-history.json"
    ])
  end

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def observe(route, at \\ System.os_time(:second)),
    do: GenServer.cast(__MODULE__, {:observe, route, at})

  def snapshot(now \\ System.os_time(:second)), do: GenServer.call(__MODULE__, {:snapshot, now})

  @impl true
  def init(opts) do
    path = Keyword.get_lazy(opts, :path, &default_path/0)
    {:ok, %{path: path, spans: load(path), previous: nil}}
  end

  @impl true
  def handle_cast({:observe, route, at}, state) do
    route = if route, do: to_string(route)
    route = if route in @routes, do: route

    spans =
      case state.previous do
        {previous, start} when not is_nil(previous) and at > start and at - start <= 90 ->
          extend(state.spans, previous, start, at)

        _ ->
          state.spans
      end
      |> clip(at - @window, at)

    if spans != state.spans, do: persist(state.path, spans)
    {:noreply, %{state | spans: spans, previous: {route, at}}}
  end

  @impl true
  def handle_call({:snapshot, now}, _from, state) do
    spans = clip(state.spans, now - @window, now)

    totals =
      Enum.reduce(spans, Map.new(@routes, &{&1, 0}), fn span, acc ->
        Map.update!(acc, span.route, &(&1 + span.end_at - span.start_at))
      end)

    covered = totals |> Map.values() |> Enum.sum()

    shares =
      Enum.map(@routes, fn route ->
        seconds = totals[route]

        %{
          route: route,
          seconds: seconds,
          percent: if(covered > 0, do: seconds * 100.0 / covered, else: 0.0)
        }
      end)

    {:reply,
     %{
       as_of: now,
       window_start: now - @window,
       intervals: Enum.reverse(spans),
       shares: shares,
       classified_seconds: covered,
       window_seconds: @window
     }, state}
  end

  defp extend([%{route: route, end_at: start} = head | rest], route, start, finish),
    do: [%{head | end_at: finish} | rest]

  defp extend(spans, route, start, finish),
    do: [%{route: route, start_at: start, end_at: finish} | spans]

  defp clip(spans, start, finish) do
    spans
    |> Enum.filter(&(&1.end_at > start and &1.start_at < finish))
    |> Enum.map(&%{&1 | start_at: max(&1.start_at, start), end_at: min(&1.end_at, finish)})
  end

  defp load(nil), do: []

  defp load(path) do
    with {:ok, data} <- File.read(path),
         {:ok, %{"version" => 1, "intervals" => intervals}} when is_list(intervals) <-
           Jason.decode(data) do
      intervals
      |> Enum.flat_map(fn
        %{"route" => r, "start_at" => s, "end_at" => e}
        when r in @routes and is_integer(s) and is_integer(e) and e > s ->
          [%{route: r, start_at: s, end_at: e}]

        _ ->
          []
      end)
      |> Enum.sort_by(& &1.start_at, :desc)
    else
      _ -> []
    end
  end

  defp persist(nil, _), do: :ok

  defp persist(path, spans) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path <> ".tmp", Jason.encode!(%{version: 1, intervals: spans})),
         :ok <- File.rename(path <> ".tmp", path) do
      :ok
    else
      {:error, reason} -> Logger.warning("[route_history] could not persist: #{inspect(reason)}")
    end
  end
end
