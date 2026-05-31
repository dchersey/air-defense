defmodule LgaPredictor.ConfigStoreTest do
  use ExUnit.Case

  alias LgaPredictor.ConfigStore

  setup do
    path = Path.join(System.tmp_dir!(), "ndcfg_#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(path) end)
    name = :"cfg_#{System.unique_integer([:positive])}"
    start_supervised!({ConfigStore, name: name, path: path})
    %{name: name, path: path}
  end

  test "creates defaults on first run", %{name: name, path: path} do
    cfg = ConfigStore.get(name)
    assert cfg.global_ceiling_ft == 6000
    assert cfg.anc_latency_seconds == 2.0
    assert cfg.zonesets == []
    # persisted to disk
    assert File.exists?(path)
  end

  test "put validates, persists, and bumps version", %{name: name, path: path} do
    v0 = ConfigStore.get(name).version

    zoneset = %{
      "id" => "z1",
      "name" => "SW arrivals",
      "enabled" => true,
      "reckoning" => "constant",
      "monitor_zone" => geojson_box(),
      "anc_zones" => [geojson_box()]
    }

    assert {:ok, cfg} = ConfigStore.put(name, %{"zonesets" => [zoneset], "global_ceiling_ft" => 4500})
    assert cfg.global_ceiling_ft == 4500
    assert cfg.version == v0 + 1
    assert [%{id: "z1", reckoning: :constant}] = cfg.zonesets

    # survives a reload from disk
    reloaded = Jason.decode!(File.read!(path))
    assert reloaded["global_ceiling_ft"] == 4500
    assert length(reloaded["zonesets"]) == 1
  end

  test "rejects invalid GeoJSON / missing fields", %{name: name} do
    assert {:error, _} = ConfigStore.put(name, %{"zonesets" => [%{"name" => "no id"}]})
    assert {:error, _} = ConfigStore.put(name, %{"global_ceiling_ft" => "high"})
  end

  test "zonesets expose Geo polygons + monitor bbox for the engine", %{name: name} do
    zoneset = %{
      "id" => "z1",
      "name" => "T",
      "enabled" => true,
      "reckoning" => "accelerating",
      "accel_kt_s" => 5.0,
      "monitor_zone" => geojson_box(),
      "anc_zones" => [geojson_box()]
    }

    {:ok, cfg} = ConfigStore.put(name, %{"zonesets" => [zoneset]})
    [zs] = cfg.zonesets

    assert {:polygon, _} = zs.monitor_zone
    assert [{:polygon, _}] = zs.anc_zones
    assert {_n, _s, _w, _e} = zs.monitor_box
    assert zs.accel_kt_s == 5.0
  end

  # A minimal GeoJSON Polygon Feature (a small box near home).
  defp geojson_box do
    %{
      "type" => "Feature",
      "properties" => %{},
      "geometry" => %{
        "type" => "Polygon",
        "coordinates" => [
          [[-73.88, 40.73], [-73.85, 40.73], [-73.85, 40.75], [-73.88, 40.75], [-73.88, 40.73]]
        ]
      }
    }
  end
end
