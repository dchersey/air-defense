defmodule LgaPredictor.ConfigStore do
  @moduledoc """
  Source of truth for user configuration: global settings + a list of **zonesets**
  (a monitor zone + ANC zones + reckoning), persisted as JSON and edited via the
  localhost API. Replaces compile-time geometry.

  The on-disk form keeps each zone's original GeoJSON (so the settings UI can
  round-trip it); the in-memory form returned by `get/1` adds derived fields the
  engine uses: `Geo` polygons and the monitor-zone bounding box.

  Default path: `~/Library/Application Support/noise-defence/config.json`
  (override with `:path`, and `:name` for isolated instances in tests).
  """

  use GenServer

  alias LgaPredictor.Geo

  @global_defaults %{
    "global_ceiling_ft" => 6000,
    "anc_latency_seconds" => 2.0,
    "version" => 0,
    "zonesets" => []
  }

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

  ## Persistence

  defp default_path do
    Path.join([System.user_home!(), "Library", "Application Support", "noise-defence", "config.json"])
  end

  defp load_or_default(path) do
    case File.read(path) do
      {:ok, body} ->
        Map.merge(@global_defaults, Jason.decode!(body))

      {:error, _} ->
        write!(path, @global_defaults)
        @global_defaults
    end
  end

  defp write!(path, raw) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(raw, pretty: true))
    File.rename!(tmp, path)
  end

  # Accept only the keys we manage; ignore unknown top-level keys.
  defp normalize_keys(incoming) do
    Map.take(incoming, ["global_ceiling_ft", "anc_latency_seconds", "zonesets"])
  end

  ## Validation

  defp validate(raw) do
    cond do
      not is_number(raw["global_ceiling_ft"]) ->
        {:error, "global_ceiling_ft must be a number"}

      not is_number(raw["anc_latency_seconds"]) ->
        {:error, "anc_latency_seconds must be a number"}

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
      not is_binary(zs["id"]) -> {:error, "zoneset.id required"}
      not is_binary(zs["name"]) -> {:error, "zoneset.name required"}
      not valid_geojson?(zs["monitor_zone"]) -> {:error, "zoneset #{zs["id"]}: invalid monitor_zone GeoJSON"}
      not is_list(zs["anc_zones"]) -> {:error, "zoneset #{zs["id"]}: anc_zones must be a list"}
      not Enum.all?(zs["anc_zones"], &valid_geojson?/1) -> {:error, "zoneset #{zs["id"]}: invalid anc_zone GeoJSON"}
      (zs["reckoning"] || "constant") not in ["constant", "accelerating"] -> {:error, "zoneset #{zs["id"]}: bad reckoning"}
      true -> :ok
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
      reckoning: reckoning_atom(zs["reckoning"]),
      accel_kt_s: zs["accel_kt_s"] || 0.0,
      altitude_ceiling_ft: zs["altitude_ceiling_ft"],
      notes: zs["notes"],
      monitor_zone: monitor,
      monitor_box: Geo.bbox(monitor),
      anc_zones: Enum.map(zs["anc_zones"], &to_polygon/1)
    }
  end

  defp reckoning_atom("accelerating"), do: :accelerating
  defp reckoning_atom(_), do: :constant

  # Accept a GeoJSON Feature, a bare Polygon geometry, or already-extracted coords.
  defp to_polygon(%{"geometry" => %{"coordinates" => coords}}), do: Geo.geojson_polygon(coords)
  defp to_polygon(%{"coordinates" => coords}), do: Geo.geojson_polygon(coords)
  defp to_polygon(coords) when is_list(coords), do: Geo.geojson_polygon(coords)
  defp to_polygon(_), do: nil
end
