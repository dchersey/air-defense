defmodule LgaPredictor.CreditLedger do
  @moduledoc """
  Self-tally of FR24 credits consumed in the current billing period.

  The FR24 Explorer plan exposes no month-to-date or remaining-balance endpoint
  (`/api/usage` returns only a short trailing window and `period=` is 403), so we
  count every credit the `Poller` spends ourselves. `seed/2` aligns the running
  total with the number shown in the FR24 dashboard (enter the *remaining* balance
  there → the caller passes `budget - remaining` as `used`); thereafter `add/2`
  tracks live.

  The period is the FR24 billing cycle: a monthly window anchored on
  `billing_reset_day` (from `ConfigStore`; 1 = calendar month). The tally rolls
  over to zero each time that anniversary passes. Persisted to a small JSON file
  so a service redeploy mid-cycle keeps the count.

  When `credit_mode` is `:reserve` there is no cycle at all: the balance is a finite
  pool of already-purchased credits (a cancelled subscription's leftovers, kept as a
  fallback) that only ever depletes. The period becomes a constant so the rollover can
  never fire — without that, the tally would silently zero every month and report a
  budget that no longer exists, which is the worst kind of wrong: quietly optimistic.
  """

  use GenServer

  alias LgaPredictor.ConfigStore

  @default_path Path.join([System.user_home() || ".", "Library", "Application Support",
                  "air-defense", "credits.json"])

  # --- API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Add `credits` to the current period's running total. Returns the new total."
  def add(server \\ __MODULE__, credits) when is_number(credits),
    do: GenServer.call(server, {:add, credits})

  @doc """
  Set the current period's total to `used` (overwrites). Use to align with the
  FR24 dashboard: pass `budget - remaining`.
  """
  def seed(server \\ __MODULE__, used) when is_number(used),
    do: GenServer.call(server, {:seed, used})

  @doc "Current period's tally as `%{period: \"YYYY-MM-DD\", used: integer}`."
  def month_to_date(server \\ __MODULE__), do: GenServer.call(server, :month_to_date)

  @doc """
  The start date of the billing cycle containing `date`, given a `reset_day`
  (day-of-month billing anniversary). `reset_day` past the month's length clamps
  to the last day of the month.
  """
  def cycle_start(%Date{} = date, reset_day) when reset_day in 1..31 do
    anchor = min(reset_day, Date.days_in_month(date))

    if date.day >= anchor do
      Date.new!(date.year, date.month, anchor)
    else
      prev_last = Date.add(Date.new!(date.year, date.month, 1), -1)
      Date.new!(prev_last.year, prev_last.month, min(reset_day, prev_last.day))
    end
  end

  # --- Server ---

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, @default_path)
    period_fun = Keyword.get(opts, :period_fun, &default_period/0)
    {period, used} = load(path)
    {:ok, %{path: path, period_fun: period_fun, period: period, used: used}}
  end

  @impl true
  def handle_call({:add, credits}, _from, state) do
    state = roll(state)
    state = %{state | used: state.used + round(credits)}
    persist(state)
    {:reply, state.used, state}
  end

  def handle_call({:seed, used}, _from, state) do
    state = roll(state)
    state = %{state | used: max(round(used), 0)}
    persist(state)
    {:reply, state.used, state}
  end

  def handle_call(:month_to_date, _from, state) do
    state = roll(state)
    {:reply, %{period: state.period, used: state.used}, state}
  end

  # Reset the tally if the billing period has advanced since we last touched it.
  defp roll(state) do
    now = state.period_fun.()
    if now == state.period, do: state, else: %{state | period: now, used: 0}
  end

  defp default_period do
    if reserve?() do
      "reserve"
    else
      {{year, month, day}, _time} = :calendar.local_time()
      cycle_start(Date.new!(year, month, day), reset_day()) |> Date.to_iso8601()
    end
  end

  defp reset_day do
    if Process.whereis(ConfigStore), do: ConfigStore.get().billing_reset_day || 1, else: 1
  end

  defp reserve? do
    Process.whereis(ConfigStore) != nil and
      Map.get(ConfigStore.get(), :credit_mode, :monthly) == :reserve
  rescue
    _ -> false
  end

  # Returns {period, used}; seeds period to the current cycle on a missing/garbled file.
  defp load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"period" => p, "used" => u}} <- Jason.decode(body),
         true <- is_binary(p) and is_integer(u) do
      {p, u}
    else
      _ -> {default_period(), 0}
    end
  end

  defp persist(%{path: path, period: period, used: used}) do
    File.mkdir_p(Path.dirname(path))
    File.write(path, Jason.encode!(%{period: period, used: used}))
  end
end
