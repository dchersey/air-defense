defmodule LgaPredictor.Customizations.LGA do
  @moduledoc "Optional LGA / Rego Park route module. See docs/customizations.md."
  alias LgaPredictor.{Approach, DepartureTrack}
  def enabled?(config), do: Map.get(config, :route_profile, :basic) == :lga_personal
  def departure_engage_bias, do: 6
  def low_overhead?(alt), do: Approach.overhead_band(alt) == :low_approach
  defdelegate track_passes(passes, aircraft, airport, home, now), to: Approach
  defdelegate route(passes, now), to: Approach
  defdelegate evidence(passes, now), to: Approach
  defdelegate arrival_tracks(aircraft, airport), to: Approach
  defdelegate runway_from_tracks(tracks, runways), to: Approach
  defdelegate observe_departures(passes, aircraft, airport, home, now), to: DepartureTrack, as: :observe
  defdelegate departure_summary(passes, now), to: DepartureTrack, as: :summary
end
