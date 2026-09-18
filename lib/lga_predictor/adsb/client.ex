defmodule LgaPredictor.ADSB.Client do
  @moduledoc """
  Local readsb/dump1090 receiver client. Fetches the receiver's full aircraft
  snapshot and trims it to the requested box, returning the same Aircraft structs
  as FR24. The suspended airplanes.live provider is explicitly disabled.
  """

  alias LgaPredictor.FR24.Aircraft

  @type bounds :: {number(), number(), number(), number()}

  @doc """
  Fetch aircraft within `bounds` ({north, south, west, east}). `opts[:provider]`
  defaults to `:local`. Returns `{:ok, [%Aircraft{}]}`.
  """
  @spec positions(bounds(), keyword()) :: {:ok, [Aircraft.t()]} | {:error, term()}
  def positions(bounds, opts \\ []) do
    case Keyword.get(opts, :provider, :local) do
      :local -> local_positions(bounds, opts)
      provider -> {:error, {:provider_disabled, provider}}
    end
  end

  defp local_positions(bounds, opts) do
    url = Keyword.get(opts, :url) || "http://adsb.local/tar1090/data/aircraft.json"

    req =
      Req.new(
        url: url,
        headers: [{"Accept", "application/json"}, {"User-Agent", "air-defense/0.1"}],
        receive_timeout: 8000,
        retry: false
      )

    case Req.get(Req.merge(req, Keyword.get(opts, :req, []))) do
      {:ok, %{status: 200, body: body}} -> {:ok, parse(body, bounds)}
      {:ok, %{status: status, body: body}} -> {:error, {:http_error, status, body}}
      {:error, exception} -> {:error, exception}
    end
  end

  @doc "Parse a readsb `%{\"ac\" => [...]}` body into Aircraft, trimmed to `bounds`."
  @spec parse(map(), bounds()) :: [Aircraft.t()]
  def parse(%{"ac" => records}, bounds) when is_list(records), do: trim(records, bounds)

  # A local readsb/dump1090 `aircraft.json` carries the identical record shape under a
  # different top-level key.
  def parse(%{"aircraft" => records}, bounds) when is_list(records), do: trim(records, bounds)

  def parse(_, _), do: []

  defp trim(records, bounds) do
    records
    |> Enum.filter(&in_box?(&1, bounds))
    |> Enum.map(&to_aircraft/1)
  end

  defp in_box?(%{"lat" => lat, "lon" => lon}, {north, south, west, east})
       when is_number(lat) and is_number(lon) do
    south <= lat and lat <= north and west <= lon and lon <= east
  end

  defp in_box?(_, _), do: false

  defp to_aircraft(a) do
    %Aircraft{
      hex: a["hex"],
      callsign: trimmed(a["flight"]),
      lat: a["lat"],
      lon: a["lon"],
      track_deg: numeric(a["track"]),
      alt_ft: altitude(a["alt_baro"]),
      gspeed_kt: numeric(a["gs"]),
      # readsb reports vertical rate as `baro_rate` OR `geom_rate` depending on what the
      # aircraft transmits, and roughly a fifth of traffic carries only the latter.
      # Reading just `baro_rate` silently reported those as level flight, which the
      # arrival filter then rejected as "not descending".
      vspeed_fpm: numeric(a["baro_rate"]) || numeric(a["geom_rate"]) || 0,
      pos_age_s: numeric(a["seen_pos"]),
      type: a["t"],
      reg: a["r"]
    }
  end

  defp altitude("ground"), do: 0
  defp altitude(v) when is_number(v), do: v
  defp altitude(_), do: nil

  defp numeric(v) when is_number(v), do: v
  defp numeric(_), do: nil

  defp trimmed(s) when is_binary(s), do: String.trim(s)
  defp trimmed(_), do: nil
end
