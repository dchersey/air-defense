defmodule LgaPredictor.Routes do
  @moduledoc """
  Best-effort callsign → airport route (origin/destination IATA) via the
  **FlightAware AeroAPI** (`/aeroapi/flights/<ident>`), which is real-time and
  delay-aware (unlike the static scheduled-route DBs, which were wrong for reused
  regional callsigns).

  Lookups are async and never block the caller: `get/2` returns the cached value
  immediately and kicks off a background fetch on a miss. Results are cached per
  callsign — a flight's route is fixed once it's airborne, so it's one query per
  unique callsign. A **monthly query cap** (persisted) protects the AeroAPI free
  tier; over the cap, or with no key, `get/2` returns `:none` so the UI falls back
  to the raw callsign.

  Returns `{:ok, origin, dest}` | `:none` | `:pending`.
  """
  use GenServer

  alias LgaPredictor.Keychain

  @name __MODULE__
  @service "air-defense-aeroapi"
  @env "AEROAPI_KEY"
  @host "https://aeroapi.flightaware.com/aeroapi"
  @default_cap 1200
  @counter_path Path.join([
                  System.user_home() || ".",
                  "Library",
                  "Application Support",
                  "air-defense",
                  "aeroapi.json"
                ])

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc "Cached route: `{:ok, origin, dest}` | `:none` | `:pending`. Blank input → `:none`."
  def get(callsign, server \\ @name)
  def get(cs, server) when is_binary(cs) and cs != "", do: GenServer.call(server, {:get, cs})
  def get(_, _), do: :none

  @doc "Whether an AeroAPI key is configured (Keychain or env)."
  def key_present?, do: Keychain.present?(@service, @env)

  @doc "Store the AeroAPI key in the Keychain and refresh the server's view of it."
  def put_key(key, server \\ @name) when is_binary(key) do
    result = Keychain.put(@service, key)
    GenServer.cast(server, :reload_key)
    result
  end

  @impl true
  def init(opts) do
    {month, count} =
      case Keyword.fetch(opts, :counter) do
        {:ok, c} -> c
        :error -> load_counter(Keyword.get(opts, :path, @counter_path))
      end

    {:ok,
     %{
       cache: %{},
       inflight: MapSet.new(),
       month: month,
       count: count,
       cap: Keyword.get(opts, :cap, Application.get_env(:lga_predictor, :aeroapi_monthly_cap, @default_cap)),
       has_key: Keyword.get(opts, :has_key, Keychain.present?(@service, @env)),
       fetch: Keyword.get(opts, :fetch, &fetch_aeroapi/1),
       path: Keyword.get(opts, :path, @counter_path)
     }}
  end

  @impl true
  def handle_call({:get, cs}, _from, state) do
    state = roll_month(state)

    case Map.get(state.cache, cs) do
      nil ->
        cond do
          not state.has_key -> {:reply, :none, state}
          state.count >= state.cap -> {:reply, :none, state}
          true -> {:reply, :pending, trigger(cs, state)}
        end

      cached ->
        {:reply, cached, state}
    end
  end

  @impl true
  def handle_cast(:reload_key, state) do
    {:noreply, %{state | has_key: Keychain.present?(@service, @env)}}
  end

  @impl true
  def handle_info({:route, cs, result}, state) do
    {:noreply,
     %{state | cache: Map.put(state.cache, cs, result), inflight: MapSet.delete(state.inflight, cs)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # One background fetch per callsign (deduped while in flight); counts against the cap.
  defp trigger(cs, state) do
    if MapSet.member?(state.inflight, cs) do
      state
    else
      parent = self()
      fetch = state.fetch
      Task.start(fn -> send(parent, {:route, cs, fetch.(cs)}) end)
      state = %{state | inflight: MapSet.put(state.inflight, cs), count: state.count + 1}
      persist(state)
      state
    end
  end

  defp roll_month(state) do
    now = current_month()
    if now == state.month, do: state, else: persist(%{state | month: now, count: 0})
  end

  defp fetch_aeroapi(callsign) do
    key = Keychain.get(@service, @env)

    if is_nil(key) do
      :none
    else
      url = "#{@host}/flights/#{URI.encode(callsign)}"

      case Req.get(url, headers: [{"x-apikey", key}], retry: false, receive_timeout: 8_000) do
        {:ok, %{status: 200, body: body}} -> select_route(body)
        _ -> :none
      end
    end
  rescue
    _ -> :none
  end

  @doc false
  # Pick the leg near the airport: the one airborne now (departed, not yet landed),
  # else the most recently departed. ISO-8601 UTC strings sort chronologically.
  def select_route(%{"flights" => flights}) when is_list(flights) do
    airborne = Enum.filter(flights, &(&1["actual_off"] && is_nil(&1["actual_on"])))
    departed = Enum.filter(flights, & &1["actual_off"])

    leg =
      cond do
        airborne != [] -> Enum.max_by(airborne, & &1["actual_off"])
        departed != [] -> Enum.max_by(departed, & &1["actual_off"])
        true -> nil
      end

    case leg do
      nil -> :none
      f -> iata(f)
    end
  end

  def select_route(_), do: :none

  defp iata(f) do
    origin = get_in(f, ["origin", "code_iata"]) || get_in(f, ["origin", "code"])
    dest = get_in(f, ["destination", "code_iata"]) || get_in(f, ["destination", "code"])

    if is_binary(origin) and origin != "" and is_binary(dest) and dest != "",
      do: {:ok, origin, dest},
      else: :none
  end

  # --- monthly counter persistence (mirrors CreditLedger) ---

  defp current_month do
    d = Date.utc_today()
    "#{d.year}-#{d.month}"
  end

  defp load_counter(path) do
    now = current_month()

    with {:ok, body} <- File.read(path),
         {:ok, %{"month" => ^now, "count" => count}} <- Jason.decode(body) do
      {now, count}
    else
      _ -> {now, 0}
    end
  end

  defp persist(%{path: path, month: month, count: count} = state) do
    File.mkdir_p(Path.dirname(path))
    File.write(path, Jason.encode!(%{month: month, count: count}))
    state
  end
end
