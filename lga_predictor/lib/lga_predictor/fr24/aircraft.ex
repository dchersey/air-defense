defmodule LgaPredictor.FR24.Aircraft do
  @moduledoc """
  A single aircraft position parsed from an FR24 flight-positions response.

  Field names are normalised to the kinematic vocabulary used by
  `LgaPredictor.Geo` (`:track_deg`, `:gspeed_kt`, `:vspeed_fpm`, `:alt_ft`), so a
  struct can be handed straight to `Geo.project/2`. The `light` endpoint omits
  `type`/`reg`/`dest_*`; those are only populated from a `full` response.
  """

  @type t :: %__MODULE__{}

  defstruct [
    :fr24_id,
    :hex,
    :callsign,
    :lat,
    :lon,
    :track_deg,
    :alt_ft,
    :gspeed_kt,
    :timestamp,
    :type,
    :reg,
    :dest_iata,
    vspeed_fpm: 0
  ]

  @doc "Build a struct from one JSON-decoded FR24 position record."
  @spec from_fr24(map()) :: t()
  def from_fr24(record) when is_map(record) do
    %__MODULE__{
      fr24_id: record["fr24_id"],
      hex: record["hex"],
      callsign: record["callsign"],
      lat: record["lat"],
      lon: record["lon"],
      track_deg: record["track"],
      alt_ft: record["alt"],
      gspeed_kt: record["gspeed"],
      vspeed_fpm: record["vspeed"] || 0,
      timestamp: record["timestamp"],
      type: record["type"],
      reg: record["reg"],
      dest_iata: record["dest_iata"]
    }
  end

  @doc "Parse a flight-positions response body (`%{\"data\" => [...]}`) into structs."
  @spec parse_positions(map()) :: [t()]
  def parse_positions(%{"data" => records}) when is_list(records) do
    Enum.map(records, &from_fr24/1)
  end

  def parse_positions(_), do: []
end
