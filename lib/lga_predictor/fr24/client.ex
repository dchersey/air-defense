defmodule LgaPredictor.FR24.Client do
  @moduledoc """
  Thin HTTP client for the FlightRadar24 API (https://fr24api.flightradar24.com).

  Credits are charged per returned flight (`:light` 6 cr/flight, `:full` 8
  cr/flight). This plan has NO access to `/count` (403), so `positions/3` is the
  only primitive — we keep the upstream box small/low and poll at 60 s during a
  manually-activated 4-hour session to stay within budget.

  Sandbox vs production is chosen by which key is used (`FR24_SANDBOX_KEY` vs
  `FR24_API_KEY`) against the same endpoints; `sandbox?: true` selects the sandbox
  key. Pure URL helpers are unit-tested; HTTP calls hit the real API.
  """

  alias LgaPredictor.FR24.Aircraft

  @host "https://fr24api.flightradar24.com"
  @accept_version "v1"

  @type kind :: :live | :historic
  @type detail :: :light | :full | :count
  # {north, south, west, east} in degrees
  @type bounds :: {number(), number(), number(), number()}

  ## Pure helpers (unit tested)

  @doc "Format `{north, south, west, east}` as the FR24 `bounds` string (N,S,W,E)."
  @spec bounds_param(bounds()) :: String.t()
  def bounds_param({north, south, west, east}) do
    Enum.map_join([north, south, west, east], ",", &to_string/1)
  end

  @doc "Build the request path for a flight-positions endpoint."
  @spec path(kind(), detail()) :: String.t()
  def path(kind, detail) do
    "/api/#{kind}/flight-positions/#{detail}"
  end

  ## HTTP calls

  @doc """
  Fetch positions in `bounds`. `detail` is `:light` (6 cr/flight) or `:full`
  (8 cr/flight, adds type/reg/dest). Returns `{:ok, [%Aircraft{}]}` or `{:error, _}`.
  """
  @spec positions(bounds(), detail(), keyword()) :: {:ok, [Aircraft.t()]} | {:error, term()}
  def positions(bounds, detail \\ :light, opts \\ []) do
    with {:ok, body} <- get(:live, detail, bounds, opts) do
      {:ok, Aircraft.parse_positions(body)}
    end
  end

  @doc """
  Fetch positions as they were at `timestamp` (unix seconds) — historic snapshot.
  Available ≤30 days back on this plan. Same per-flight cost as live.
  """
  @spec historic_positions(bounds(), integer(), detail(), keyword()) ::
          {:ok, [Aircraft.t()]} | {:error, term()}
  def historic_positions(bounds, timestamp, detail \\ :light, opts \\ []) do
    params = Map.merge(%{timestamp: timestamp}, Keyword.get(opts, :params, %{}))

    with {:ok, body} <- get(:historic, detail, bounds, Keyword.put(opts, :params, params)) do
      {:ok, Aircraft.parse_positions(body)}
    end
  end

  defp get(kind, detail, bounds, opts) do
    sandbox? = Keyword.get(opts, :sandbox?, sandbox_default())

    params = Map.merge(%{bounds: bounds_param(bounds)}, Keyword.get(opts, :params, %{}))

    base = [
      base_url: @host,
      url: path(kind, detail),
      params: params,
      headers: [
        {"Accept", "application/json"},
        {"Accept-Version", @accept_version},
        {"Authorization", "Bearer " <> api_key(sandbox?)}
      ]
    ]

    req = Req.new(Keyword.merge(base, Keyword.get(opts, :req, [])))

    case Req.get(req) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end

  defp sandbox_default do
    :lga_predictor |> Application.get_env(:fr24, %{}) |> Map.get(:sandbox?, false)
  end

  defp api_key(true = _sandbox?) do
    System.get_env("FR24_SANDBOX_KEY") || raise "FR24_SANDBOX_KEY environment variable is not set"
  end

  defp api_key(false = _sandbox?) do
    System.get_env("FR24_API_KEY") || raise "FR24_API_KEY environment variable is not set"
  end
end
