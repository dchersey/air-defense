defmodule LgaPredictor.Sources do
  @moduledoc """
  Dispatches a monitor-zone fetch to the configured flight-data provider, so the
  `Poller` is source-agnostic. All providers return the same
  `LgaPredictor.FR24.Aircraft` structs.

    :airplanes_live → free ADS-B feed (no key, no credits)
    :fr24           → FlightRadar24 (API key, billed per flight)
  """

  alias LgaPredictor.{ADSB, FR24}

  @spec positions(FR24.Client.bounds(), atom(), keyword()) ::
          {:ok, [FR24.Aircraft.t()]} | {:error, term()}
  def positions(bounds, provider, opts \\ [])

  def positions(bounds, :fr24, opts), do: FR24.Client.positions(bounds, :light, opts)

  def positions(bounds, :airplanes_live, opts) do
    ADSB.Client.positions(bounds, Keyword.put(opts, :provider, :airplanes_live))
  end
end
