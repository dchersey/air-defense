import Config

# Tests start Actuator/Poller themselves via start_supervised!, so don't
# auto-start the named singletons in the application tree.
config :lga_predictor, start_workers: false

# Don't make real HTTP calls to the keep-alive endpoint during tests.
config :lga_predictor, keep_alive_enabled: false
