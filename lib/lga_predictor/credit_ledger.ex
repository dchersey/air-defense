defmodule LgaPredictor.CreditLedger do
  @moduledoc """
  Self-tally of FR24 credits consumed in the current calendar month.

  The FR24 Explorer plan exposes no month-to-date or remaining-balance endpoint
  (`/api/usage` returns only a short trailing window and `period=` is 403), so we
  count every credit the `Poller` spends ourselves. `seed/2` aligns the running
  total with the number shown in the FR24 dashboard (enter the *remaining* balance
  there → the caller passes `budget - remaining` as `used`); thereafter `add/2`
  tracks live. The tally rolls over to zero at each calendar-month boundary.

  Persisted to a small JSON file so a service redeploy mid-month keeps the count.
  """

  use GenServer

  @default_path Path.join([System.user_home() || ".", "Library", "Application Support",
                  "noise-defence", "credits.json"])

  # --- API ---

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Add `credits` to the current month's running total. Returns the new total."
  def add(server \\ __MODULE__, credits) when is_number(credits),
    do: GenServer.call(server, {:add, credits})

  @doc """
  Set the current month's total to `used` (overwrites). Use to align with the
  FR24 dashboard: pass `budget - remaining`.
  """
  def seed(server \\ __MODULE__, used) when is_number(used),
    do: GenServer.call(server, {:seed, used})

  @doc "Current month's tally as `%{month: \"YYYY-MM\", used: integer}`."
  def month_to_date(server \\ __MODULE__), do: GenServer.call(server, :month_to_date)

  # --- Server ---

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, @default_path)
    month_fun = Keyword.get(opts, :month_fun, &default_month/0)
    {month, used} = load(path)
    {:ok, %{path: path, month_fun: month_fun, month: month, used: used}}
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
    {:reply, %{month: state.month, used: state.used}, state}
  end

  # Reset the tally if the calendar month has advanced since we last touched it.
  defp roll(state) do
    now = state.month_fun.()
    if now == state.month, do: state, else: %{state | month: now, used: 0}
  end

  defp default_month do
    {{year, month, _day}, _time} = :calendar.local_time()
    "#{year}-#{String.pad_leading(Integer.to_string(month), 2, "0")}"
  end

  # Returns {month, used}; seeds month to the current month on a missing/garbled file.
  defp load(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"month" => m, "used" => u}} <- Jason.decode(body),
         true <- is_binary(m) and is_integer(u) do
      {m, u}
    else
      _ -> {default_month(), 0}
    end
  end

  defp persist(%{path: path, month: month, used: used}) do
    File.mkdir_p(Path.dirname(path))
    File.write(path, Jason.encode!(%{month: month, used: used}))
  end
end
