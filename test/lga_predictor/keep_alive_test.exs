defmodule LgaPredictor.KeepAliveTest do
  # Not async: mutates the application env (keep_alive_url) for the duration.
  use ExUnit.Case, async: false

  alias LgaPredictor.KeepAlive

  test "on/off fail quietly (return :error, never raise) when the endpoint is absent" do
    prev = Application.get_env(:lga_predictor, :keep_alive_url)
    # Port 9 (discard) with nothing bound → immediate connection refused.
    Application.put_env(:lga_predictor, :keep_alive_url, "http://127.0.0.1:9")
    on_exit(fn -> Application.put_env(:lga_predictor, :keep_alive_url, prev) end)

    assert KeepAlive.on() == :error
    assert KeepAlive.off() == :error
  end
end
