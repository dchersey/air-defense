import Config

# FR24 keys are read at runtime from the environment so they never live in source.
# FR24_API_KEY (production) is required when the actuator runs against live data;
# FR24_SANDBOX_KEY is only needed for sandbox? = true.
if config_env() != :test do
  # Presence is validated lazily by LgaPredictor.FR24.Client; nothing to set here yet.
  :ok
end
