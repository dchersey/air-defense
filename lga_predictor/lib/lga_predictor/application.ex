defmodule LgaPredictor.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:lga_predictor, :start_workers, true) do
        [LgaPredictor.Actuator, LgaPredictor.Poller]
      else
        []
      end

    opts = [strategy: :one_for_one, name: LgaPredictor.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
