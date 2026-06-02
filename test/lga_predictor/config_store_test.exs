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
    assert cfg.max_dwell_seconds == 30
    assert cfg.zonesets == []
    # persisted to disk
    assert File.exists?(path)
  end

  test "billing_reset_day defaults to 1 and round-trips a valid day", %{name: name} do
    assert ConfigStore.get(name).billing_reset_day == 1

    assert {:ok, cfg} = ConfigStore.put(name, %{"billing_reset_day" => 15})
    assert cfg.billing_reset_day == 15
  end

  test "billing_reset_day rejects out-of-range / non-integer values", %{name: name} do
    assert {:error, _} = ConfigStore.put(name, %{"billing_reset_day" => 0})
    assert {:error, _} = ConfigStore.put(name, %{"billing_reset_day" => 32})
    assert {:error, _} = ConfigStore.put(name, %{"billing_reset_day" => 1.5})
    # unchanged after rejected writes
    assert ConfigStore.get(name).billing_reset_day == 1
  end

  test "zoneset min_gspeed_kt defaults to 150 and round-trips a custom value", %{name: name} do
    base = %{
      "id" => "z1",
      "name" => "T",
      "enabled" => true,
      "monitor_zone" => geojson_box(),
      "anc_zones" => [geojson_box()]
    }

    {:ok, cfg} = ConfigStore.put(name, %{"zonesets" => [base]})
    assert [%{min_gspeed_kt: 150}] = cfg.zonesets

    {:ok, cfg} = ConfigStore.put(name, %{"zonesets" => [Map.put(base, "min_gspeed_kt", 180)]})
    assert [%{min_gspeed_kt: 180}] = cfg.zonesets
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

  test "zoneset poll_interval_ms is optional (nil when absent) and round-trips", %{name: name} do
    base = %{
      "id" => "z1",
      "name" => "T",
      "monitor_zone" => geojson_box(),
      "anc_zones" => [geojson_box()]
    }

    {:ok, cfg} = ConfigStore.put(name, %{"zonesets" => [base]})
    assert [%{poll_interval_ms: nil}] = cfg.zonesets

    {:ok, cfg} = ConfigStore.put(name, %{"zonesets" => [Map.put(base, "poll_interval_ms", 5000)]})
    assert [%{poll_interval_ms: 5000}] = cfg.zonesets
  end

  test "rejects a non-number poll_interval_ms", %{name: name} do
    bad = %{
      "id" => "z1",
      "name" => "T",
      "monitor_zone" => geojson_box(),
      "anc_zones" => [geojson_box()],
      "poll_interval_ms" => "fast"
    }

    assert {:error, _} = ConfigStore.put(name, %{"zonesets" => [bad]})
  end

  test "add_zoneset assigns an id, defaults trigger, persists, bumps version", %{name: name} do
    v0 = ConfigStore.get(name).version

    assert {:ok, id} =
             ConfigStore.add_zoneset(name, %{
               "name" => "Arrivals SW",
               "monitor_zone" => geojson_box(),
               "anc_zones" => [geojson_box()]
             })

    assert is_binary(id)
    cfg = ConfigStore.get(name)
    assert cfg.version == v0 + 1
    assert [%{id: ^id, name: "Arrivals SW", trigger: :assume, enabled: true}] = cfg.zonesets
  end

  test "add_zoneset accepts a FeatureCollection for a zone", %{name: name} do
    fc = %{"type" => "FeatureCollection", "features" => [geojson_box()]}

    assert {:ok, _id} =
             ConfigStore.add_zoneset(name, %{
               "name" => "FC",
               "monitor_zone" => fc,
               "anc_zones" => [fc]
             })

    assert [%{monitor_zone: {:polygon, [_ | _]}}] = ConfigStore.get(name).zonesets
  end

  test "add_zoneset rejects invalid GeoJSON", %{name: name} do
    assert {:error, _} =
             ConfigStore.add_zoneset(name, %{
               "name" => "bad",
               "monitor_zone" => %{"not" => "geojson"},
               "anc_zones" => [geojson_box()]
             })
  end

  test "update_zoneset renames / replaces a zone; unknown id errors", %{name: name} do
    {:ok, id} =
      ConfigStore.add_zoneset(name, %{
        "name" => "A",
        "monitor_zone" => geojson_box(),
        "anc_zones" => [geojson_box()]
      })

    assert :ok = ConfigStore.update_zoneset(name, id, %{"name" => "Renamed"})
    assert [%{name: "Renamed"}] = ConfigStore.get(name).zonesets

    assert {:error, :not_found} = ConfigStore.update_zoneset(name, "nope", %{"name" => "x"})
    assert {:error, _} = ConfigStore.update_zoneset(name, id, %{"monitor_zone" => %{"bad" => 1}})
  end

  test "delete_zoneset removes it; unknown id errors", %{name: name} do
    {:ok, id} =
      ConfigStore.add_zoneset(name, %{
        "name" => "A",
        "monitor_zone" => geojson_box(),
        "anc_zones" => [geojson_box()]
      })

    assert :ok = ConfigStore.delete_zoneset(name, id)
    assert ConfigStore.get(name).zonesets == []
    assert {:error, :not_found} = ConfigStore.delete_zoneset(name, "nope")
  end

  test "list_zonesets returns raw zonesets with original GeoJSON (for copy-out)", %{name: name} do
    {:ok, id} =
      ConfigStore.add_zoneset(name, %{
        "name" => "A",
        "monitor_zone" => geojson_box(),
        "anc_zones" => [geojson_box()]
      })

    assert [zs] = ConfigStore.list_zonesets(name)
    assert zs["id"] == id
    assert zs["monitor_zone"]["type"] == "Feature"
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
