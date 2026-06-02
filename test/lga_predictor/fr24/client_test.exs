defmodule LgaPredictor.FR24.ClientTest do
  use ExUnit.Case, async: true

  alias LgaPredictor.FR24.Client

  describe "bounds_param/1" do
    test "formats {north, south, west, east} as the FR24 N,S,W,E string" do
      assert Client.bounds_param({40.93, 40.53, -74.10, -73.63}) == "40.93,40.53,-74.1,-73.63"
    end
  end

  describe "path/2" do
    test "builds live and historic flight-positions paths under /api" do
      assert Client.path(:live, :light) == "/api/live/flight-positions/light"
      assert Client.path(:live, :full) == "/api/live/flight-positions/full"
      assert Client.path(:historic, :light) == "/api/historic/flight-positions/light"
    end
  end

  describe "parse_usage_total/1" do
    test "sums the (string) credits across endpoints" do
      body = %{"data" => [%{"credits" => "1674"}, %{"credits" => "6"}, %{"credits" => 8}]}
      assert Client.parse_usage_total(body) == 1688
    end

    test "is zero for an empty/odd body" do
      assert Client.parse_usage_total(%{"data" => []}) == 0
      assert Client.parse_usage_total(%{}) == 0
    end
  end
end
