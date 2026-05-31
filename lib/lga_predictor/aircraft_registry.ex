defmodule LgaPredictor.AircraftRegistry do
  @moduledoc """
  Tracks each aircraft's recent samples across polls so the predictor can use
  along-track **acceleration** (departing planes speed up). The `Poller` calls
  `observe/3` each poll with the freshly-fetched aircraft; it returns the same
  aircraft enriched with `:accel_kt_s` (Δgroundspeed ÷ Δt vs. the previous
  sample, `0.0` on first sighting).

  Keyed by `:hex` (falling back to `:fr24_id`). Entries not seen within `ttl`
  are pruned each `observe/3`. Multiple named instances are supported for tests.
  """

  use Agent

  @default_ttl 300

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    ttl = Keyword.get(opts, :ttl_seconds, @default_ttl)
    Agent.start_link(fn -> %{seen: %{}, ttl: ttl} end, name: name)
  end

  @doc """
  Record this poll's `aircraft`, returning each enriched with `:accel_kt_s`
  derived from its previous sample. `:now` (unix seconds) defaults to wall clock.
  """
  def observe(name, aircraft, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:second) end)

    Agent.get_and_update(name, fn %{seen: seen, ttl: ttl} = state ->
      seen = prune(seen, now, ttl)

      {enriched, seen} =
        Enum.map_reduce(aircraft, seen, fn ac, acc ->
          key = key_for(ac)
          accel = accel_for(acc[key], ac, now)
          sample = %{ts: now, gspeed_kt: Map.get(ac, :gspeed_kt)}
          {Map.put(ac, :accel_kt_s, accel), Map.put(acc, key, sample)}
        end)

      {enriched, %{state | seen: seen}}
    end)
  end

  @doc "Whether `key` is currently tracked (testing/introspection)."
  def tracked?(name, key) do
    Agent.get(name, fn %{seen: seen} -> Map.has_key?(seen, key) end)
  end

  ## Internals

  defp key_for(ac), do: Map.get(ac, :hex) || Map.get(ac, :fr24_id)

  defp accel_for(nil, _ac, _now), do: 0.0

  defp accel_for(%{ts: prev_ts, gspeed_kt: prev_gs}, ac, now) do
    gs = Map.get(ac, :gspeed_kt)
    dt = now - prev_ts

    if is_number(gs) and is_number(prev_gs) and dt > 0 do
      (gs - prev_gs) / dt
    else
      0.0
    end
  end

  defp prune(seen, now, ttl) do
    seen
    |> Enum.reject(fn {_key, %{ts: ts}} -> now - ts > ttl end)
    |> Map.new()
  end
end
