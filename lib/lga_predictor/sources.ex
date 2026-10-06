defmodule LgaPredictor.Sources do
  @moduledoc """
  Dispatches a monitor-zone fetch to the configured flight-data provider, so the
  `Poller` is source-agnostic. All providers return the same
  `LgaPredictor.FR24.Aircraft` structs.

    :local          → local ADS-B receiver (no key, no credits)
    :airplanes_live → free IP-authorized feeder fallback
    :fr24           → FlightRadar24 (API key, billed per flight)
  """

  alias LgaPredictor.{ADSB, FR24}

  @spec positions(FR24.Client.bounds(), atom(), keyword()) ::
          {:ok, [FR24.Aircraft.t()]} | {:error, term()}
  def positions(bounds, provider, opts \\ [])

  def positions(bounds, :fr24, opts), do: FR24.Client.positions(bounds, :light, opts)

  def positions(bounds, :local, opts) do
    ADSB.Client.positions(bounds, Keyword.put(opts, :provider, :local))
  end

  def positions(bounds, :airplanes_live, _opts),
    do: ADSB.Fallback.positions(bounds)
end
