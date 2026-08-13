defmodule LgaPredictor.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    start_workers? =
      System.get_env("LGA_NO_SERVER") != "1" and
        Application.get_env(:lga_predictor, :start_workers, true)

    children =
      if start_workers? do
        port = Application.get_env(:lga_predictor, :api_port, 4040)

        [
          LgaPredictor.ConfigStore,
          {LgaPredictor.AircraftRegistry, name: LgaPredictor.AircraftRegistry},
          LgaPredictor.Actuator,
          LgaPredictor.History,
          LgaPredictor.Routes,
          LgaPredictor.CreditLedger,
          LgaPredictor.Poller,
          {Bandit, plug: LgaPredictor.API.Router, scheme: :http, ip: {127, 0, 0, 1}, port: port}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: LgaPredictor.Supervisor]
    result = Supervisor.start_link(children, opts)
    if start_workers?, do: warn_missing_keys()
    result
  end

  # A provider whose key has gone missing fails only at poll time, as a fetch error —
  # which reads like a network blip. Keychain items don't survive a Mac migration, so
  # this is a real way to end up silently blind. Say so once, at startup.
  defp warn_missing_keys do
    config = LgaPredictor.ConfigStore.get()

    if config.provider == :fr24 and not LgaPredictor.FR24.Client.key_present?() do
      Logger.warning(
        "[startup] provider is FlightRadar24 but no API key is stored — every poll will " <>
          "fail. Paste a key in Settings → Data source, or switch provider."
      )
    end

    unless LgaPredictor.Routes.key_present?() do
      Logger.info(
        "[startup] no FlightAware AeroAPI key — recent flights will show raw callsigns " <>
          "instead of routes (optional; everything else works)."
      )
    end
  rescue
    # Never let a diagnostic stop the app from booting.
    e -> Logger.warning("[startup] key check failed: #{inspect(e)}")
  end
end
