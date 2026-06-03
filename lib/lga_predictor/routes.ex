defmodule LgaPredictor.Routes do
  @moduledoc """
  Best-effort callsign → airport route (origin/destination IATA).

  ADS-B carries no route, so we look it up by callsign via the free **adsbdb** API
  (`https://api.adsbdb.com/v0/callsign/<cs>`) and cache it — routes per callsign are
  stable, so a hit is cheap. Lookups are async and never block the caller: `get/2`
  returns the cached value immediately and kicks off a background fetch on a miss.
  Airline callsigns resolve to `{:ok, origin, dest}`; GA/private/unknown callsigns
  cache as `:none` (the UI shows "private").
  """
  use GenServer
  require Logger

  @name __MODULE__

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Cached route for `callsign`:
    * `{:ok, origin_iata, dest_iata}` — known route
    * `:none` — fetched, no route (GA/private/unknown), or blank/non-binary input
    * `:pending` — a fetch was just kicked off; try again shortly
  """
  def get(callsign, server \\ @name)

  def get(callsign, server) when is_binary(callsign) and callsign != "" do
    GenServer.call(server, {:get, callsign})
  end

  def get(_, _), do: :none

  @impl true
  def init(opts) do
    {:ok,
     %{
       cache: %{},
       inflight: MapSet.new(),
       fetch: Keyword.get(opts, :fetch, &fetch_adsbdb/1)
     }}
  end

  @impl true
  def handle_call({:get, cs}, _from, state) do
    case Map.get(state.cache, cs) do
      nil -> {:reply, :pending, trigger(cs, state)}
      cached -> {:reply, cached, state}
    end
  end

  @impl true
  def handle_info({:route, cs, result}, state) do
    {:noreply,
     %{state | cache: Map.put(state.cache, cs, result), inflight: MapSet.delete(state.inflight, cs)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Fire one background fetch per callsign (deduped while in flight).
  defp trigger(cs, state) do
    if MapSet.member?(state.inflight, cs) do
      state
    else
      parent = self()
      fetch = state.fetch
      Task.start(fn -> send(parent, {:route, cs, fetch.(cs)}) end)
      %{state | inflight: MapSet.put(state.inflight, cs)}
    end
  end

  defp fetch_adsbdb(callsign) do
    url = "https://api.adsbdb.com/v0/callsign/#{URI.encode(callsign)}"

    case Req.get(url, retry: false, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: body}} -> parse(body)
      _ -> :none
    end
  rescue
    _ -> :none
  end

  @doc false
  # Map an adsbdb response body to a route. Anything unexpected → :none.
  def parse(%{"response" => %{"flightroute" => fr}}) when is_map(fr) do
    origin = get_in(fr, ["origin", "iata_code"])
    dest = get_in(fr, ["destination", "iata_code"])

    if is_binary(origin) and origin != "" and is_binary(dest) and dest != "" do
      {:ok, origin, dest}
    else
      :none
    end
  end

  def parse(_), do: :none
end
