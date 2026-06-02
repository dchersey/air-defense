defmodule LgaPredictor.CreditUsage do
  @moduledoc """
  Caches FR24 month-to-date credit consumption (from `GET /api/usage`), refreshed
  on a slow timer so it doesn't eat into the request rate limit. The API reports
  what's been *consumed*; paired with the plan allotment (config
  `:monthly_credit_budget`) the panel shows a usage-vs-time pace bar.

  Best-effort: on a fetch error (e.g. rate-limited) it keeps the last value. The
  fetcher is injectable for tests.
  """

  use GenServer

  @refresh_ms 5 * 60 * 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Last-known credits consumed this period (`nil` until the first fetch)."
  def used(name \\ __MODULE__), do: GenServer.call(name, :used)

  ## Server

  @impl true
  def init(opts) do
    state = %{
      used: nil,
      fetcher: Keyword.get(opts, :fetcher, &default_fetch/0),
      interval: Keyword.get(opts, :refresh_ms, @refresh_ms)
    }

    send(self(), :refresh)
    {:ok, state}
  end

  @impl true
  def handle_call(:used, _from, state), do: {:reply, state.used, state}

  @impl true
  def handle_info(:refresh, state) do
    used =
      case state.fetcher.() do
        {:ok, n} -> n
        _ -> state.used
      end

    Process.send_after(self(), :refresh, state.interval)
    {:noreply, %{state | used: used}}
  end

  defp default_fetch, do: LgaPredictor.FR24.Client.usage()
end
