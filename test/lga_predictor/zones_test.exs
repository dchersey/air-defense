defmodule LgaPredictor.ZonesTest do
  use ExUnit.Case, async: true

  alias LgaPredictor.Zones

  @sample """
  {
    "type": "FeatureCollection",
    "features": [
      {
        "type": "Feature",
        "properties": {"name": "departure_noise_on"},
        "geometry": {
          "type": "Polygon",
          "coordinates": [[[-73.880,40.743],[-73.873,40.743],[-73.873,40.748],[-73.880,40.748],[-73.880,40.743]]]
        }
      },
      {
        "type": "Feature",
        "properties": {"name": "arrival_noise"},
        "geometry": {
          "type": "Polygon",
          "coordinates": [[[-73.880,40.728],[-73.850,40.728],[-73.850,40.734],[-73.880,40.734],[-73.880,40.728]]]
        }
      }
    ]
  }
  """

  test "parse/1 maps each feature name to a {:polygon, ...} zone" do
    zones = Zones.parse(@sample)

    assert {:polygon, on_pts} = zones["departure_noise_on"]
    # GeoJSON [lon,lat] became {lat,lon}; closing vertex dropped.
    assert {40.743, -73.880} in on_pts
    assert length(on_pts) == 4

    assert Map.has_key?(zones, "arrival_noise")
  end

  test "accepts `id` as an alternative to `name`" do
    json = ~s({"type":"FeatureCollection","features":[
      {"type":"Feature","properties":{"id":"x"},
       "geometry":{"type":"Polygon","coordinates":[[[-73.9,40.7],[-73.8,40.7],[-73.8,40.75],[-73.9,40.7]]]}}]})

    zones = Zones.parse(json)
    assert Map.has_key?(zones, "x")
  end

  test "fetch!/2 returns a zone or raises with a helpful message" do
    zones = Zones.parse(@sample)
    assert {:polygon, _} = Zones.fetch!(zones, "arrival_noise")

    assert_raise KeyError, ~r/missing/, fn -> Zones.fetch!(zones, "nope") end
  end
end
