defmodule LgaPredictor.Predictor do
  @moduledoc """
  Decides whether an aircraft will pass through the noise zone (below the
  altitude ceiling) within the prediction window, by dead-reckoning its position
  forward in small steps. Pure — no process state.

  Returns the ANC timing relative to "now": `:enters_in` / `:exits_in` seconds and
  the `:dwell_seconds` it is expected to be overhead, or `nil` if it won't qualify.
  """

  alias LgaPredictor.Geo

  @required [:lat, :lon, :track_deg, :gspeed_kt, :alt_ft]

  @type result :: %{enters_in: number(), exits_in: number(), dwell_seconds: number()}

  @spec predict_overflight(map(), keyword()) :: result() | nil
  def predict_overflight(aircraft, opts) do
    zone = Keyword.fetch!(opts, :noise_zone)
    window = Keyword.get(opts, :window_seconds, 90)
    ceiling = Keyword.get(opts, :altitude_ceiling_ft, 4500)
    step = Keyword.get(opts, :step_seconds, 5)
    accel = Keyword.get(opts, :accel_kt_s, 0.0)

    if missing_kinematics?(aircraft) do
      nil
    else
      0
      |> Stream.iterate(&(&1 + step))
      |> Enum.take_while(&(&1 <= window))
      |> Enum.filter(&in_zone_and_low?(aircraft, &1, zone, ceiling, accel))
      |> summarise()
    end
  end

  @doc """
  Two-zone prediction for departures: engage ANC when the projected path first
  reaches `:noise_on_zone`, release when it first reaches `:noise_off_zone`
  (a distinct zone further along the arc). Returns `%{engage_in:, release_in:}`
  seconds-from-now, or `nil` if the path never reaches the on-zone (below the
  ceiling) within the window. Honors `:accel_kt_s` for accelerating departures.
  """
  @spec predict_traversal(map(), keyword()) :: %{engage_in: number(), release_in: number()} | nil
  def predict_traversal(aircraft, opts) do
    on_zone = Keyword.fetch!(opts, :noise_on_zone)
    off_zone = Keyword.fetch!(opts, :noise_off_zone)
    window = Keyword.get(opts, :window_seconds, 120)
    ceiling = Keyword.get(opts, :altitude_ceiling_ft, 6000)
    step = Keyword.get(opts, :step_seconds, 5)
    accel = Keyword.get(opts, :accel_kt_s, 0.0)

    if missing_kinematics?(aircraft) do
      nil
    else
      times = 0 |> Stream.iterate(&(&1 + step)) |> Enum.take_while(&(&1 <= window))
      engage = Enum.find(times, &in_zone_and_low?(aircraft, &1, on_zone, ceiling, accel))

      if engage do
        release =
          times
          |> Enum.drop_while(&(&1 < engage))
          |> Enum.find(&in_zone_and_low?(aircraft, &1, off_zone, ceiling, accel))

        # If the off-zone isn't reached in-window, hold until the window edge.
        %{engage_in: engage, release_in: release || window}
      else
        nil
      end
    end
  end

  @doc """
  Map a list of aircraft to overflight windows, dropping those that won't pass
  through the noise zone. Each result is the `predict_overflight/2` map with the
  originating `:aircraft` attached.
  """
  @spec overflight_windows([map()], keyword()) :: [map()]
  def overflight_windows(aircraft, opts) do
    aircraft
    |> Enum.map(fn ac -> {ac, predict_overflight(ac, opts)} end)
    |> Enum.reject(fn {_ac, result} -> is_nil(result) end)
    |> Enum.map(fn {ac, result} -> Map.put(result, :aircraft, ac) end)
  end

  defp in_zone_and_low?(aircraft, t, zone, ceiling, accel) do
    projected = Geo.project(aircraft, t, accel_kt_s: accel)
    projected.alt_ft < ceiling and Geo.point_in_zone?({projected.lat, projected.lon}, zone)
  end

  defp summarise([]), do: nil

  defp summarise(times) do
    enters = hd(times)
    exits = List.last(times)
    %{enters_in: enters, exits_in: exits, dwell_seconds: exits - enters}
  end

  defp missing_kinematics?(aircraft) do
    Enum.any?(@required, &is_nil(Map.get(aircraft, &1)))
  end
end
