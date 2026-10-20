defmodule LgaPredictor.SettingsTransfer do
  @moduledoc "Versioned portable settings; credentials and device state are never exported."
  @fields ~w(route_profile global_ceiling_ft anc_latency_seconds max_dwell_seconds engage_delta_seconds release_delta_seconds home_lat home_lon acoustic_decay_seconds airport_lat airport_lon runways provider local_feed_url zonesets)
  @zone_fields ~w(id name enabled type reckoning trigger accel_kt_s assume_delay_seconds assume_duration_seconds altitude_ceiling_ft min_gspeed_kt poll_interval_ms engage_delta_seconds release_delta_seconds monitor_zone anc_zones)

  def export(raw), do: %{format: "air-defense-settings", version: 1, settings: sanitize(raw)}

  def decode(%{"format" => "air-defense-settings", "version" => 1, "settings" => settings}) when is_map(settings) do
    {:ok, sanitize(settings)}
  rescue
    _ -> {:error, "Malformed settings file"}
  end
  def decode(_), do: {:error, "Expected an Air Defense settings file (version 1)"}

  defp sanitize(raw) do
    raw |> Map.take(@fields)
    |> Map.update("zonesets", [], fn zones ->
      Enum.map(zones, fn zone ->
        zone |> Map.take(@zone_fields)
        |> Map.update!("monitor_zone", &geometry/1)
        |> Map.update!("anc_zones", &Enum.map(&1, fn g -> geometry(g) end))
      end)
    end)
    |> Map.update("local_feed_url", "http://adsb.local/tar1090/data/aircraft.json", fn url ->
      uri = URI.parse(url)
      %{uri | userinfo: nil, query: nil, fragment: nil} |> URI.to_string()
    end)
    |> Map.update("runways", [], &Enum.map(&1, fn r -> Map.take(r, ["name", "heading"]) end))
  end

  defp geometry(%{"type" => "FeatureCollection", "features" => features}),
    do: %{"type" => "FeatureCollection", "features" => Enum.map(features, &geometry/1)}
  defp geometry(%{"type" => "Feature", "geometry" => g}),
    do: %{"type" => "Feature", "properties" => %{}, "geometry" => geometry(g)}
  defp geometry(%{"type" => "Polygon", "coordinates" => coords}),
    do: %{"type" => "Polygon", "coordinates" => coords}
  defp geometry(_), do: nil
end
