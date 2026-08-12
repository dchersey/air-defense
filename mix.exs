defmodule LgaPredictor.MixProject do
  use Mix.Project

  def project do
    [
      app: :lga_predictor,
      version: "0.9.1",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  # Self-contained release for end users: `MIX_ENV=prod mix release` bundles the
  # Erlang runtime, so the install script's tarball needs no Elixir/Erlang on the
  # target. Named `air_defense` → bin/air_defense (what the launchd agent runs).
  defp releases do
    [
      air_defense: [
        include_executables_for: [:unix],
        applications: [lga_predictor: :permanent]
      ]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {LgaPredictor.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:plug, "~> 1.16"},
      {:bandit, "~> 1.5"}
    ]
  end
end
