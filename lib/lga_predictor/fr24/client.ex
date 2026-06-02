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

  @doc """
  Total API credits consumed, summed across endpoints, from `GET /api/usage`.
  Metadata (not flight data) — but still counts against the request rate limit.
  Returns `{:ok, credits}` or `{:error, _}`.
  """
  @spec usage(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def usage(opts \\ []) do
    sandbox? = Keyword.get(opts, :sandbox?, sandbox_default())

    req =
      Req.new(
        base_url: @host,
        url: "/api/usage",
        params: Keyword.get(opts, :params, %{}),
        headers: [
          {"Accept", "application/json"},
          {"Accept-Version", @accept_version},
          {"Authorization", "Bearer " <> api_key(sandbox?)}
        ]
      )

    case Req.get(Req.merge(req, Keyword.get(opts, :req, []))) do
      {:ok, %{status: 200, body: body}} -> {:ok, parse_usage_total(body)}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end

  @doc "Sum the `credits` across a `/api/usage` response body (credits are strings)."
  @spec parse_usage_total(map()) :: non_neg_integer()
  def parse_usage_total(%{"data" => rows}) when is_list(rows) do
    rows |> Enum.map(&usage_credits/1) |> Enum.sum()
  end

  def parse_usage_total(_), do: 0

  defp usage_credits(%{"credits" => c}) when is_binary(c), do: String.to_integer(c)
  defp usage_credits(%{"credits" => c}) when is_integer(c), do: c
  defp usage_credits(_), do: 0

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

  # Resolve the FR24 token: macOS Keychain first (no secret in env/plist), then
  # the env var as a fallback for tests, scripts, and non-macOS/CI.
  defp api_key(sandbox?) do
    {service, env} =
      if sandbox?,
        do: {"air-defense-fr24-sandbox", "FR24_SANDBOX_KEY"},
        else: {"air-defense-fr24", "FR24_API_KEY"}

    keychain_key(service) || System.get_env(env) ||
      raise "FR24 key not found (keychain service #{inspect(service)} or env #{env})"
  end

  @doc "True if an FR24 key is available (Keychain or env) for the production service."
  @spec key_present?() :: boolean()
  def key_present? do
    keychain_key("air-defense-fr24") != nil or System.get_env("FR24_API_KEY") != nil
  end

  @doc """
  Store the production FR24 key in the login Keychain (service `air-defense-fr24`),
  replacing any existing entry. Lets the menu-bar app set the key without the user
  touching the `security` CLI. Returns `:ok` or `{:error, output}`.
  """
  @spec put_key(String.t()) :: :ok | {:error, String.t()}
  def put_key(key) when is_binary(key) do
    service = "air-defense-fr24"
    account = System.get_env("USER") || "air-defense"
    # Delete first so we never accumulate duplicate items under different accounts.
    System.cmd("security", ["delete-generic-password", "-s", service], stderr_to_stdout: true)

    case System.cmd("security", ["add-generic-password", "-a", account, "-s", service, "-w", key],
           stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end

  defp keychain_key(service) do
    case System.cmd("security", ["find-generic-password", "-s", service, "-w"],
           stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    # `security` absent (e.g. CI/Linux) — fall through to the env var.
    _ -> nil
  end
end
