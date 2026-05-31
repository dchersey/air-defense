defmodule LgaPredictor.Patterns do
  @moduledoc """
  The stereotyped LGA operations the predictor recognises. Each is a named map
  with its own geometry, altitude ceiling, expected track range, and reckoning
  mode. The Poller fetches the **union** approach box once, then runs each enabled
  pattern's predictor over the aircraft that match it.

  Geometry coordinates are `{lat, lon}`; boxes are `{north, south, west, east}`.
  Home (Thornton Pl, Rego Park) ≈ {40.727, −73.860}.

  ## Patterns

  - `:arrival_sw` — arrivals on the curved approach from the SW, descending over
    Rego Park. Exact geometry carried over from the validated single-pattern
    config. Constant-speed reckoning.
  - `:departure_arc` — departures off LGA that vector S/SW over Astoria/Woodside,
    curve through Jackson Heights/Elmhurst/Corona, and arc back NE past 108th St.
    These **accelerate** along the arc, so reckoning is `:accelerating`. Audible
    from ~Roosevelt Ave (lat 40.748) until clearing 108th St (lon −73.855).
    Geometry geocoded from street descriptions — REVIEW/tune against live passes.
  """

  @type pattern :: %{
          id: atom(),
          label: String.t(),
          approach_box: {number(), number(), number(), number()},
          noise_zone: LgaPredictor.Geo.zone(),
          altitude_ceiling_ft: number(),
          track_range: {number(), number()},
          reckoning: :constant | :accelerating
        }

  @arrival_sw %{
    id: :arrival_sw,
    label: "Arrivals (SW)",
    approach_box: {40.738, 40.678, -73.945, -73.850},
    noise_zone:
      {:polygon, [{40.728, -73.880}, {40.734, -73.880}, {40.734, -73.850}, {40.728, -73.850}]},
    altitude_ceiling_ft: 4500,
    # Arrivals track roughly NE/ENE across the noise band.
    track_range: {30, 130},
    reckoning: :constant
  }

  @departure_arc %{
    id: :departure_arc,
    label: "Departures (arc)",
    # Wide box: LGA/Astoria (N) down through Woodside/Jackson Heights/Elmhurst/
    # Corona to past 108th St (E). Covers the whole arc.
    approach_box: {40.775, 40.730, -73.930, -73.845},
    # Audible band: south of Roosevelt Ave (lat 40.748), west of 108th St
    # (lon −73.855), down to ~home latitude, east of Junction Blvd (lon −73.890).
    noise_zone:
      {:polygon, [{40.731, -73.890}, {40.748, -73.890}, {40.748, -73.855}, {40.731, -73.855}]},
    altitude_ceiling_ft: 6000,
    # Departures sweep through E/SE while turning; accept a wide track band.
    track_range: {40, 200},
    reckoning: :accelerating
  }

  @patterns [@arrival_sw, @departure_arc]

  @doc "All known patterns."
  @spec all() :: [pattern()]
  def all, do: @patterns

  @doc "Look up a pattern by id."
  @spec get(atom()) :: pattern() | nil
  def get(id), do: Enum.find(@patterns, &(&1.id == id))

  @doc """
  Smallest `{north, south, west, east}` box covering every given pattern's
  approach box — one FR24 poll feeds all of them. Defaults to all patterns.
  """
  @spec union_box([pattern()]) :: {number(), number(), number(), number()}
  def union_box(patterns \\ @patterns) do
    boxes = Enum.map(patterns, & &1.approach_box)

    {
      boxes |> Enum.map(&elem(&1, 0)) |> Enum.max(),
      boxes |> Enum.map(&elem(&1, 1)) |> Enum.min(),
      boxes |> Enum.map(&elem(&1, 2)) |> Enum.min(),
      boxes |> Enum.map(&elem(&1, 3)) |> Enum.max()
    }
  end
end
