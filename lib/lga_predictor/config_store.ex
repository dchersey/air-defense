defmodule LgaPredictor.ConfigStore do
  @moduledoc """
  Source of truth for user configuration: global settings + a list of **zonesets**
  (a monitor zone + ANC zones + reckoning), persisted as JSON and edited via the
  localhost API. Replaces compile-time geometry.

  The on-disk form keeps each zone's original GeoJSON (so the settings UI can
  round-trip it); the in-memory form returned by `get/1` adds derived fields the
  engine uses: `Geo` polygons and the monitor-zone bounding box.

  Default path: `~/Library/Application Support/air-defense/config.json`
  (override with `:path`, and `:name` for isolated instances in tests).
  """

  use GenServer

  alias LgaPredictor.Geo

  @global_defaults %{
    "global_ceiling_ft" => 6000,
    "anc_latency_seconds" => 2.0,
    "max_dwell_seconds" => 30,
    # Manual offsets (seconds) added to the computed engage/release times — a
    # control-panel tuning knob. 0 = use the service's estimate as-is.
    "engage_delta_seconds" => 0,
    "release_delta_seconds" => 0,
    # Day of month the FR24 credit allotment resets (billing anniversary). The
    # credit ledger rolls over on this day and the pace bar measures the cycle
    # from it. 1 = calendar month (default until the real billing day is known).
    "billing_reset_day" => 1,
    # Flight-data source for ALL zones: "airplanes_live" (free ADS-B, no key) or
    # "fr24" (FlightRadar24, needs an API key, costs credits).
    "provider" => "airplanes_live",
    "version" => 0,
    "zonesets" => []
  }

  @providers ~w(airplanes_live fr24)
  @default_min_gspeed_kt 150

  ## API

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Current config, with derived engine fields (polygons + monitor_box)."
  def get(name \\ __MODULE__), do: GenServer.call(name, :get)

  @doc "Raw, JSON-serialisable config (string keys, original GeoJSON) for the API/UI."
  def raw(name \\ __MODULE__), do: GenServer.call(name, :raw)

  @doc """
  Replace config from a (string-keyed) map — typically the API body. Validates,
  persists atomically, bumps `version`. Returns `{:ok, derived}` or `{:error, reason}`.
  """
  def put(name \\ __MODULE__, raw) when is_map(raw), do: GenServer.call(name, {:put, raw})

  @doc "Raw zonesets (string keys, original GeoJSON) — for listing + copy-out."
  def list_zonesets(name \\ __MODULE__), do: GenServer.call(name, :list_zonesets)

  @doc """
  Add a zoneset from `attrs` (`"name"`, `"monitor_zone"`, `"anc_zones"`, optional
  `"trigger"`). Assigns an id from the name, defaults trigger `:assume` + enabled.
  Returns `{:ok, id}` or `{:error, reason}` (invalid/duplicate geometry).
  """
  def add_zoneset(name \\ __MODULE__, attrs) when is_map(attrs),
    do: GenServer.call(name, {:add_zoneset, attrs})

  @doc "Merge `fields` into zoneset `id` (rename, replace a zone). Validated."
  def update_zoneset(name \\ __MODULE__, id, fields) when is_binary(id) and is_map(fields),
    do: GenServer.call(name, {:update_zoneset, id, fields})

  @doc "Delete zoneset `id`. `{:error, :not_found}` if it doesn't exist."
  def delete_zoneset(name \\ __MODULE__, id) when is_binary(id),
    do: GenServer.call(name, {:delete_zoneset, id})

  ## Server

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, default_path())
    raw = load_or_default(path)
    {:ok, %{path: path, raw: raw}}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, derive(state.raw), state}
  end

  def handle_call(:raw, _from, state) do
    {:reply, state.raw, state}
  end

  def handle_call({:put, incoming}, _from, state) do
    merged = Map.merge(state.raw, normalize_keys(incoming))

    case validate(merged) do
      :ok ->
        merged = Map.put(merged, "version", (state.raw["version"] || 0) + 1)
        write!(state.path, merged)
        {:reply, {:ok, derive(merged)}, %{state | raw: merged}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call(:list_zonesets, _from, state), do: {:reply, zonesets(state), state}

  def handle_call({:add_zoneset, attrs}, _from, state) do
    id = gen_id(attrs["name"], Enum.map(zonesets(state), & &1["id"]))

    zoneset =
      attrs
      |> Map.put("id", id)
      |> Map.put_new("enabled", true)
      |> Map.put_new("trigger", "assume")

    raw = Map.put(state.raw, "zonesets", zonesets(state) ++ [zoneset])
    persist_if_valid(raw, state, {:ok, id})
  end

  def handle_call({:update_zoneset, id, fields}, _from, state) do
    if Enum.any?(zonesets(state), &(&1["id"] == id)) do
      updated =
        Enum.map(zonesets(state), fn zs ->
          if zs["id"] == id, do: Map.merge(zs, fields), else: zs
        end)

      persist_if_valid(Map.put(state.raw, "zonesets", updated), state, :ok)
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete_zoneset, id}, _from, state) do
    if Enum.any?(zonesets(state), &(&1["id"] == id)) do
      kept = Enum.reject(zonesets(state), &(&1["id"] == id))
      persist_if_valid(Map.put(state.raw, "zonesets", kept), state, :ok)
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  ## Persistence

  defp default_path do
    Path.join([
      System.user_home!(),
      "Library",
      "Application Support",
      "air-defense",
      "config.json"
    ])
  end

  defp load_or_default(path) do
    case File.read(path) do
      {:ok, body} ->
        @global_defaults |> Map.merge(Jason.decode!(body)) |> migrate_legacy()

      {:error, _} ->
        write!(path, @global_defaults)
        @global_defaults
    end
  end

  # adsb.lol was removed as a provider (unreliable — TCP connects routinely time out).
  # Fold any stored "adsb_lol" back to the default so an existing config keeps working
  # and stays valid instead of failing validation on the next edit.
  defp migrate_legacy(%{"provider" => "adsb_lol"} = raw),
    do: %{raw | "provider" => "airplanes_live"}

  defp migrate_legacy(raw), do: raw

  defp zonesets(state), do: state.raw["zonesets"] || []

  # Validate the candidate config; persist + bump version only if it's valid.
  defp persist_if_valid(raw, state, ok_reply) do
    case validate(raw) do
      :ok ->
        raw = Map.put(raw, "version", (state.raw["version"] || 0) + 1)
        write!(state.path, raw)
        {:reply, ok_reply, %{state | raw: raw}}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  # A url-safe id derived from the name, made unique against existing ids.
  defp gen_id(name, existing) do
    base =
      name
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    base = if base == "", do: "zone", else: base
    dedupe(base, existing, 0)
  end

  defp dedupe(base, existing, n) do
    candidate = if n == 0, do: base, else: "#{base}-#{n}"
    if candidate in existing, do: dedupe(base, existing, n + 1), else: candidate
  end

  defp write!(path, raw) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(raw, pretty: true))
    File.rename!(tmp, path)
  end

  # Accept only the keys we manage; ignore unknown top-level keys.
  defp normalize_keys(incoming) do
    Map.take(incoming, [
      "global_ceiling_ft",
      "anc_latency_seconds",
      "max_dwell_seconds",
      "engage_delta_seconds",
      "release_delta_seconds",
      "billing_reset_day",
      "provider",
      "zonesets"
    ])
  end

  ## Validation

  defp validate(raw) do
    cond do
      not is_number(raw["global_ceiling_ft"]) ->
        {:error, "global_ceiling_ft must be a number"}

      not is_number(raw["anc_latency_seconds"]) ->
        {:error, "anc_latency_seconds must be a number"}

      not is_number(raw["max_dwell_seconds"]) ->
        {:error, "max_dwell_seconds must be a number"}

      not is_number(raw["engage_delta_seconds"]) ->
        {:error, "engage_delta_seconds must be a number"}

      not is_number(raw["release_delta_seconds"]) ->
        {:error, "release_delta_seconds must be a number"}

      not (is_integer(raw["billing_reset_day"]) and raw["billing_reset_day"] in 1..31) ->
        {:error, "billing_reset_day must be an integer 1..31"}

      raw["provider"] not in @providers ->
        {:error, "provider must be one of #{Enum.join(@providers, ", ")}"}

      not is_list(raw["zonesets"]) ->
        {:error, "zonesets must be a list"}

      true ->
        Enum.reduce_while(raw["zonesets"], :ok, fn zs, _ ->
          case validate_zoneset(zs) do
            :ok -> {:cont, :ok}
            err -> {:halt, err}
          end
        end)
    end
  end

  defp validate_zoneset(zs) do
    cond do
      not is_binary(zs["id"]) ->
        {:error, "zoneset.id required"}

      not is_binary(zs["name"]) ->
        {:error, "zoneset.name required"}

      not valid_geojson?(zs["monitor_zone"]) ->
        {:error, "zoneset #{zs["id"]}: invalid monitor_zone GeoJSON"}

      not is_list(zs["anc_zones"]) ->
        {:error, "zoneset #{zs["id"]}: anc_zones must be a list"}

      not Enum.all?(zs["anc_zones"], &valid_geojson?/1) ->
        {:error, "zoneset #{zs["id"]}: invalid anc_zone GeoJSON"}

      (zs["reckoning"] || "constant") not in ["constant", "accelerating"] ->
        {:error, "zoneset #{zs["id"]}: bad reckoning"}

      (zs["trigger"] || "predict") not in ["predict", "assume"] ->
        {:error, "zoneset #{zs["id"]}: bad trigger"}

      (zs["type"] || "arrival") not in ["arrival", "departure"] ->
        {:error, "zoneset #{zs["id"]}: bad type"}

      not is_nil(zs["min_gspeed_kt"]) and not is_number(zs["min_gspeed_kt"]) ->
        {:error, "zoneset #{zs["id"]}: min_gspeed_kt must be a number"}

      not is_nil(zs["poll_interval_ms"]) and not is_number(zs["poll_interval_ms"]) ->
        {:error, "zoneset #{zs["id"]}: poll_interval_ms must be a number"}

      not is_nil(zs["engage_delta_seconds"]) and not is_number(zs["engage_delta_seconds"]) ->
        {:error, "zoneset #{zs["id"]}: engage_delta_seconds must be a number"}

      not is_nil(zs["release_delta_seconds"]) and not is_number(zs["release_delta_seconds"]) ->
        {:error, "zoneset #{zs["id"]}: release_delta_seconds must be a number"}

      true ->
        :ok
    end
  end

  defp valid_geojson?(feature) do
    match?({:polygon, [_ | _]}, to_polygon(feature))
  rescue
    _ -> false
  end

  ## Derivation (raw JSON -> engine-ready struct)

  defp derive(raw) do
    %{
      global_ceiling_ft: raw["global_ceiling_ft"],
      anc_latency_seconds: raw["anc_latency_seconds"],
      max_dwell_seconds: raw["max_dwell_seconds"],
      engage_delta_seconds: raw["engage_delta_seconds"],
      release_delta_seconds: raw["release_delta_seconds"],
      billing_reset_day: raw["billing_reset_day"],
      provider: provider_atom(raw["provider"]),
      version: raw["version"],
      zonesets: Enum.map(raw["zonesets"], &derive_zoneset/1)
    }
  end

  defp derive_zoneset(zs) do
    monitor = to_polygon(zs["monitor_zone"])

    %{
      id: zs["id"],
      name: zs["name"],
      enabled: Map.get(zs, "enabled", true),
      type: type_atom(zs["type"]),
      reckoning: reckoning_atom(zs["reckoning"]),
      accel_kt_s: zs["accel_kt_s"] || 0.0,
      trigger: trigger_atom(zs["trigger"]),
      min_gspeed_kt: zs["min_gspeed_kt"] || @default_min_gspeed_kt,
      poll_interval_ms: zs["poll_interval_ms"],
      # Per-zone ANC timing offsets (seconds); nil → fall back to the global offset.
      # Lets arrival vs departure zones be calibrated independently (their geometry
      # differs, so one global pair forces a re-tune on every zone switch).
      engage_delta_seconds: zs["engage_delta_seconds"],
      release_delta_seconds: zs["release_delta_seconds"],
      assume_delay_seconds: zs["assume_delay_seconds"] || 0.0,
      assume_duration_seconds: zs["assume_duration_seconds"] || 30.0,
      altitude_ceiling_ft: zs["altitude_ceiling_ft"],
      notes: zs["notes"],
      monitor_zone: monitor,
      monitor_box: Geo.bbox(monitor),
      anc_zones: Enum.map(zs["anc_zones"], &to_polygon/1)
    }
  end

  # Explicit (compile-baked) string→atom map. NOT String.to_existing_atom: under
  # the dev `mix run` runtime the provider's defining module may not be loaded yet,
  # so its atom wouldn't exist. These literals live in this (always-loaded) module.
  defp provider_atom("fr24"), do: :fr24
  defp provider_atom(_), do: :airplanes_live

  defp reckoning_atom("accelerating"), do: :accelerating
  defp reckoning_atom(_), do: :constant

  # :departure — engage ANC on actual ANC-zone entry (variable turn points make a
  # straight-line ETA unreliable); :arrival (default) — ETA-scheduled engage.
  defp type_atom("departure"), do: :departure
  defp type_atom(_), do: :arrival

  # :assume — any qualifying detection in the monitor zone triggers ANC (for
  # banking departures where straight-line projection into the ANC zone fails);
  # :predict (default) — dead-reckon the path into the ANC zone.
  defp trigger_atom("assume"), do: :assume
  defp trigger_atom(_), do: :predict

  # Accept a GeoJSON FeatureCollection (use its first polygon — geojson.io's export
  # for a single drawn shape), a Feature, a bare Polygon geometry, or raw coords.
  defp to_polygon(%{"type" => "FeatureCollection", "features" => [feature | _]}),
    do: to_polygon(feature)

  defp to_polygon(%{"geometry" => %{"coordinates" => coords}}), do: Geo.geojson_polygon(coords)
  defp to_polygon(%{"coordinates" => coords}), do: Geo.geojson_polygon(coords)
  defp to_polygon(coords) when is_list(coords), do: Geo.geojson_polygon(coords)
  defp to_polygon(_), do: nil
end
