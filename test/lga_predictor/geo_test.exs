defmodule LgaPredictor.GeoTest do
  use ExUnit.Case, async: true

  alias LgaPredictor.Geo

  describe "haversine_km/2" do
    test "distance from a point to itself is zero" do
      p = {40.728, -73.864}
      assert Geo.haversine_km(p, p) == 0.0
    end

    test "one degree of latitude is about 111.19 km (R=6371)" do
      assert_in_delta Geo.haversine_km({0.0, 0.0}, {1.0, 0.0}), 111.19, 0.05
    end
  end

  describe "project/2 (straight-line dead reckoning)" do
    test "due-north travel advances latitude (360 kt for 60 s = 0.1 deg)" do
      state = %{lat: 0.0, lon: 0.0, track_deg: 0.0, gspeed_kt: 360.0, vspeed_fpm: 0.0, alt_ft: 3000.0}
      projected = Geo.project(state, 60)
      assert_in_delta projected.lat, 0.1, 1.0e-4
      assert_in_delta projected.lon, 0.0, 1.0e-4
    end

    test "due-east longitude advance scales by 1/cos(latitude)" do
      at_equator = %{lat: 0.0, lon: 0.0, track_deg: 90.0, gspeed_kt: 360.0, vspeed_fpm: 0.0, alt_ft: 0.0}
      at_60n = %{at_equator | lat: 60.0}

      assert_in_delta Geo.project(at_equator, 60).lon, 0.1, 1.0e-4
      # cos(60 deg) = 0.5, so the same ground track moves twice as many degrees of longitude
      assert_in_delta Geo.project(at_60n, 60).lon, 0.2, 1.0e-4
    end

    test "altitude changes by vertical rate over the interval" do
      climbing = %{lat: 0.0, lon: 0.0, track_deg: 0.0, gspeed_kt: 0.0, vspeed_fpm: 1200.0, alt_ft: 2000.0}
      # +1200 fpm for 60 s = +1200 ft
      assert_in_delta Geo.project(climbing, 60).alt_ft, 3200.0, 1.0e-6
    end

    test "acceleration adds the integral of accel over the interval to ground distance" do
      # Due north, gs0 = 0 kt, accel = 6 kt/s, for 60 s.
      # Distance covered = integral of (accel*t) dt = 0.5*accel*t^2 (in kt·s units)
      #   = 0.5 * 6 * 60^2 = 10800 kt·s  ->  /216000 = 0.05 deg latitude.
      state = %{lat: 0.0, lon: 0.0, track_deg: 0.0, gspeed_kt: 0.0, vspeed_fpm: 0.0, alt_ft: 0.0}
      assert_in_delta Geo.project(state, 60, accel_kt_s: 6.0).lat, 0.05, 1.0e-4
    end

    test "accel defaults to zero (constant-speed projection unchanged)" do
      state = %{lat: 0.0, lon: 0.0, track_deg: 0.0, gspeed_kt: 360.0, vspeed_fpm: 0.0, alt_ft: 0.0}
      assert Geo.project(state, 60) == Geo.project(state, 60, accel_kt_s: 0.0)
    end
  end

  describe "point_in_zone?/2 with a circle zone" do
    @circle {:circle, {0.0, 0.0}, 111.19}

    test "the centre is inside" do
      assert Geo.point_in_zone?({0.0, 0.0}, @circle)
    end

    test "a point within the radius is inside" do
      # ~55.6 km north, well inside a 111.19 km radius
      assert Geo.point_in_zone?({0.5, 0.0}, @circle)
    end

    test "a point beyond the radius is outside" do
      # ~166 km north, outside a 111.19 km radius
      refute Geo.point_in_zone?({1.5, 0.0}, @circle)
    end
  end

  describe "point_in_zone?/2 with a polygon zone" do
    # A unit square around the origin.
    @square {:polygon, [{0.0, 0.0}, {0.0, 1.0}, {1.0, 1.0}, {1.0, 0.0}]}

    test "a point inside the polygon is inside" do
      assert Geo.point_in_zone?({0.5, 0.5}, @square)
    end

    test "a point outside the polygon is outside" do
      refute Geo.point_in_zone?({1.5, 0.5}, @square)
      refute Geo.point_in_zone?({-0.5, 0.5}, @square)
    end
  end
end
