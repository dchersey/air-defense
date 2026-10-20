defmodule LgaPredictor.SettingsTransferTest do
  use ExUnit.Case
  alias LgaPredictor.ConfigStore, as: C
  setup do
    path = Path.join(System.tmp_dir!(), "portable-#{System.unique_integer([:positive])}.json")
    name = :portable_config
    start_supervised!({C, name: name, path: path})
    on_exit(fn -> File.rm(path); File.rm(path <> ".before-import") end)
    %{name: name, path: path}
  end
  defp packet(settings), do: %{"format" => "air-defense-settings", "version" => 1, "settings" => settings}

  test "new installs are basic, while the original location migrates to its personal profile", %{path: path} do
    assert C.get(:portable_config).route_profile == :basic
    stop_supervised!(C)
    File.write!(path, Jason.encode!(%{"home_lat" => 40.722832, "home_lon" => -73.857549,
      "airport_lat" => 40.7772, "airport_lon" => -73.8726}))
    start_supervised!({C, name: :portable_config, path: path})
    assert C.get(:portable_config).route_profile == :lga_personal
    assert {:ok, _} = C.put(:portable_config, %{"route_profile" => "basic"})
    stop_supervised!(C)
    start_supervised!({C, name: :portable_config, path: path})
    assert C.get(:portable_config).route_profile == :basic
  end

  test "export strips secrets and import preserves local billing, backs up and replaces portable settings", %{name: name, path: path} do
    assert {:ok, _} = C.put(name, %{"credit_mode" => "reserve", "home_lat" => 12, "home_lon" => 34,
      "local_feed_url" => "https://user:secret@receiver.test/data.json?token=secret"})
    raw = C.raw(name) |> Map.put("api_key", "secret")
    exported = LgaPredictor.SettingsTransfer.export(raw) |> Jason.encode!() |> Jason.decode!()
    refute Jason.encode!(exported) =~ "secret"
    assert exported["settings"]["local_feed_url"] == "https://receiver.test/data.json"
    assert {:ok, _} = C.import_settings(name, exported)
    assert C.get(name).home_coords == {12, 34}
    assert C.get(name).credit_mode == :reserve
    assert File.exists?(path <> ".before-import")
  end

  test "portable zones round trip and invalid zone values are rejected", %{name: name, path: path} do
    raw = File.read!("config.example.json") |> Jason.decode!()
    exported = LgaPredictor.SettingsTransfer.export(raw) |> Jason.encode!() |> Jason.decode!()
    assert {:ok, config} = C.import_settings(name, exported)
    assert length(config.zonesets) == length(raw["zonesets"])
    assert C.raw(name)["zonesets"] == exported["settings"]["zonesets"]
    before = File.read!(path)
    [zone | _] = raw["zonesets"]
    for zones <- [[zone, zone], [Map.put(zone, "poll_interval_ms", 0)],
      [Map.put(zone, "altitude_ceiling_ft", "high")], [Map.put(zone, "monitor_zone", %{})],
      [Map.put(zone, "monitor_zone", %{"type" => "Polygon", "coordinates" => [[["bad", 40], [1, 2], [3, 4]]]})]] do
      assert {:error, _} = C.import_settings(name, packet(%{"zonesets" => zones}))
      assert File.read!(path) == before
    end
  end

  test "invalid imports leave config and file unchanged", %{name: name, path: path} do
    before = File.read!(path)
    for bad <- [packet(%{"home_lat" => 99}), packet(%{"zonesets" => [7]}),
      packet(%{"route_profile" => "unknown"}), packet(%{"anc_latency_seconds" => -1}),
      %{"format" => "air-defense-settings", "version" => 2, "settings" => %{}}] do
      assert {:error, _} = C.import_settings(name, bad)
      assert File.read!(path) == before
    end
    assert Process.alive?(Process.whereis(name))
  end
end
