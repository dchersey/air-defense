import Config

# Tests start Actuator/Poller themselves via start_supervised!, so don't
# auto-start the named singletons in the application tree.
config :lga_predictor, start_workers: false
