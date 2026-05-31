defmodule LgaPredictor.KeepAlive do
  @moduledoc """
  Best-effort client for the standalone **Keep Sound Alive** control endpoint
  (a separate menu-bar app). The Poller pushes a hold when monitoring starts and
  pops it when it stops, so AirPods don't idle-disconnect mid-session. The
  keep-alive app is optional — if it isn't running, calls just fail quietly.
  """

  require Logger

  @doc "Push a hold (start keeping the output awake)."
  def on, do: post("/on")

  @doc "Pop a hold (stop, unless other holds remain)."
  def off, do: post("/off")

  defp post(path) do
    url = Application.get_env(:lga_predictor, :keep_alive_url, "http://127.0.0.1:4500") <> path

    case Req.post(url, json: %{}, receive_timeout: 1000, retry: false) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.debug("[keep_alive] #{path} unreachable: #{inspect(reason)}"); :error
    end
  rescue
    e -> Logger.debug("[keep_alive] #{path} error: #{inspect(e)}"); :error
  end
end
