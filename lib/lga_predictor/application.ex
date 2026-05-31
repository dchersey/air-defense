defmodule LgaPredictor.Application do
  @moduledoc false

  use Application

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
          LgaPredictor.Poller,
          {Bandit, plug: LgaPredictor.API.Router, scheme: :http, ip: {127, 0, 0, 1}, port: port}
        ]
      else
        []
      end

    opts = [strategy: :one_for_one, name: LgaPredictor.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
