defmodule LgaPredictor.Zones do
  @moduledoc """
  Loads named geofence polygons from a GeoJSON `FeatureCollection` — the format
  exported from Google Maps (My Maps) or geojson.io. Each `Feature` is keyed by
  its `name` (or `id`) property and converted to a `LgaPredictor.Geo` polygon
  zone (GeoJSON `[lon, lat]` → `{lat, lon}`).

  Expected feature names for this project:
  `arrival_noise`, `arrival_detect` (optional), `departure_detect`,
  `departure_noise_on`, `departure_noise_off`.
  """

  alias LgaPredictor.Geo

  @doc "Load + parse a GeoJSON file at `path` into `%{name => zone}`."
  @spec load(Path.t()) :: %{String.t() => Geo.zone()}
  def load(path), do: path |> File.read!() |> parse()

  @doc "Parse a GeoJSON FeatureCollection string into `%{name => zone}`."
  @spec parse(String.t()) :: %{String.t() => Geo.zone()}
  def parse(json) do
    %{"features" => features} = Jason.decode!(json)

    for %{"geometry" => %{"type" => "Polygon", "coordinates" => coords}} = feature <- features,
        name = feature_name(feature),
        into: %{} do
      {name, Geo.geojson_polygon(coords)}
    end
  end

  @doc "Fetch a named zone, raising a helpful error if absent."
  @spec fetch!(%{String.t() => Geo.zone()}, String.t()) :: Geo.zone()
  def fetch!(zones, name) do
    case Map.fetch(zones, name) do
      {:ok, zone} ->
        zone

      :error ->
        raise KeyError,
          message: "zone #{inspect(name)} missing; have: #{inspect(Map.keys(zones))}"
    end
  end

  defp feature_name(%{"properties" => props}) when is_map(props) do
    props["name"] || props["id"]
  end

  defp feature_name(_), do: nil
end
