defmodule LgaPredictor.History do
  @moduledoc """
  In-memory ring buffer of recent overflight-trigger events, for the control
  panel's recent-flights list and frequency graph. Bounded; oldest events drop.

  Events are maps with at least `:at` (unix seconds) plus `:callsign`, `:alt_ft`,
  `:enters_in`, `:dwell`. The `Poller` records one per dispatched window.
  """

  use Agent

  @default_max 200

  def start_link(opts \\ []) do
    max = Keyword.get(opts, :max, @default_max)
    Agent.start_link(fn -> %{events: [], max: max} end, name: __MODULE__)
  end

  @doc "Record one trigger event (most-recent-first; truncated to :max)."
  def record(event) when is_map(event) do
    Agent.update(__MODULE__, fn %{events: events, max: max} = state ->
      %{state | events: Enum.take([event | events], max)}
    end)
  end

  @doc "Most-recent-first list of up to `limit` events."
  def recent(limit \\ 50) do
    Agent.get(__MODULE__, fn %{events: events} -> Enum.take(events, limit) end)
  end

  @doc "All retained events, most-recent-first."
  def all do
    Agent.get(__MODULE__, fn %{events: events} -> events end)
  end

  @doc """
  Trigger counts grouped into `buckets` windows of `bucket_seconds`, oldest→newest,
  covering `(now - buckets*bucket_seconds, now]`. `:now` defaults to current time.
  """
  def counts_per_bucket(bucket_seconds, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)
    n = Keyword.fetch!(opts, :buckets)
    start = now - n * bucket_seconds

    initial = List.duplicate(0, n)

    all()
    |> Enum.filter(&(&1.at >= start and &1.at <= now))
    |> Enum.reduce(initial, fn e, acc ->
      idx = min(div(e.at - start, bucket_seconds), n - 1)
      List.update_at(acc, idx, &(&1 + 1))
    end)
  end
end
