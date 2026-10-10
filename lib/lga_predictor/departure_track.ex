defmodule LgaPredictor.DepartureTrack do
  @moduledoc "Personal LGA departure-track inference, independent of arrival routing and ANC."
  alias LgaPredictor.{Approach, Geo}
  @retention 1200

  def observe(passes, aircraft, airport, home, now) do
    aircraft
    |> Enum.filter(&eligible?(&1, airport))
    |> Enum.reduce(passes, fn ac, acc ->
      key = ac.hex || ac.callsign
      if is_nil(key) do
        acc
      else
        prior = Map.get(acc, key)
        prior = if prior && now - prior.last_seen <= 90, do: prior, else: nil
        seed = south_launch?(ac, airport)
        if prior || seed do
          distance = Geo.haversine_km(home, {ac.lat, ac.lon}) / 1.852
          p = prior || %{first_at: now, first_lon: ac.lon, first_alt: ac.alt_ft,
            closest_nm: distance, closest_alt: ac.alt_ft, confirmed: false}
          eastward = ac.track_deg >= 35 and ac.track_deg <= 120 and
            (ac.lon - p.first_lon) * 60 * :math.cos(ac.lat * :math.pi() / 180) >= 0.3 and
            now - p.first_at >= 5 and ac.alt_ft >= p.first_alt + 200
          nearer = distance < p.closest_nm
          Map.put(acc, key, Map.merge(p, %{last_seen: now, last_nm: distance,
            closest_nm: min(p.closest_nm, distance),
            closest_alt: if(nearer, do: ac.alt_ft, else: p.closest_alt),
            confirmed: p.confirmed or eastward, callsign: ac.callsign || key, type: ac.type}))
        else
          acc
        end
      end
    end)
    |> Map.filter(fn {_, p} -> now - p.last_seen < @retention end)
  end

  def summary(passes, now) do
    completed = passes |> Map.values() |> Enum.filter(fn p ->
      p.confirmed and now - p.last_seen < @retention and
        (p.last_nm > p.closest_nm + 0.3 or now - p.last_seen > 30)
    end)
    nearest = Enum.min_by(completed, & &1.closest_nm, fn -> nil end)
    %{track: if(length(completed) >= 2, do: "south → east", else: nil),
      count: length(completed), closest_nm: nearest && Float.round(nearest.closest_nm, 2),
      closest_alt_ft: nearest && nearest.closest_alt, callsign: nearest && nearest.callsign}
  end

  defp south_launch?(ac, airport) do
    Geo.haversine_km(airport, {ac.lat, ac.lon}) <= 2 * 1.852 and
      ac.lat < elem(airport, 0) and ac.alt_ft <= 3500 and
      (ac.vspeed_fpm || 0) >= 300 and ac.track_deg >= 140 and ac.track_deg <= 240
  end

  defp eligible?(ac, airport) do
    Approach.airliner?(ac) and is_number(ac.lat) and is_number(ac.lon) and
      is_number(ac.alt_ft) and ac.alt_ft >= 200 and ac.alt_ft < 10000 and
      is_number(ac.track_deg) and is_number(ac.gspeed_kt) and
      ac.gspeed_kt >= 80 and ac.gspeed_kt <= 350 and
      (ac.vspeed_fpm || 0) >= -200 and (ac.pos_age_s || 0) <= 15 and
      Geo.haversine_km(airport, {ac.lat, ac.lon}) <= 15 * 1.852
  end
end
