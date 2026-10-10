defmodule LgaPredictor.DepartureTrackTest do
  use ExUnit.Case, async: true
  alias LgaPredictor.DepartureTrack, as: D
  alias LgaPredictor.FR24.Aircraft
  @airport {40.7772, -73.8726}
  @home {40.722832, -73.857549}
  defp ac(id, lat, lon, alt, track, vs \\ 1400) do
    %Aircraft{hex: id, callsign: id, type: "E75L", lat: lat, lon: lon,
      alt_ft: alt, track_deg: track, vspeed_fpm: vs, gspeed_kt: 200, pos_age_s: 1}
  end
  defp observe(p, a, t), do: D.observe(p, a, @airport, @home, t)
  defp tracks do
    observe(%{}, [ac("wide",40.767,-73.885,600,220), ac("tight",40.767,-73.885,600,220)], 100)
    |> observe([ac("wide",40.728,-73.86,2400,80), ac("tight",40.750,-73.87,1800,80)], 145)
    |> observe([ac("wide",40.75,-73.80,4000,60), ac("tight",40.76,-73.80,4000,60)], 180)
  end
  test "tight and wide turns share a track, with measured proximity kept separately" do
    p = tracks()
    assert p["wide"].closest_nm < p["tight"].closest_nm
    assert %{track: "south → east", count: 2, callsign: "wide", closest_alt_ft: 2400} = D.summary(p,180)
    assert D.summary(Map.delete(p,"tight"),180).track == nil
    assert D.summary(p,1380).track == nil
  end
  test "requires a climbing launch near LGA followed by an observed eastward turn" do
    for a <- [ac("x",40.767,-73.885,600,220,-700), ac("x",40.70,-73.98,600,220),
              ac("x",40.767,-73.885,600,60), %{ac("x",40.767,-73.885,600,220) | pos_age_s: 30},
              %{ac("x",40.767,-73.885,600,220) | type: "B06"}] do
      assert observe(%{},[a],100) == %{}
    end
    p=observe(%{},[ac("x",40.767,-73.885,600,220)],100)
    assert D.summary(p,200).count == 0
    # A long reception gap cannot join unrelated segments into a turn.
    p=observe(p,[ac("x",40.728,-73.86,2400,80)],200)
    assert D.summary(p,240).count == 0
  end
  test "eastbound observation without altitude gain does not confirm departure" do
    p=observe(%{},[ac("x",40.767,-73.885,600,220)],100)
      |> observe([ac("x",40.75,-73.85,650,80,0)],120)
    assert D.summary(p,200).count == 0
  end
end
