defmodule LgaPredictor.Keychain do
  @moduledoc """
  Thin wrapper over the macOS `security` CLI for storing API keys out of config
  and git. Reads fall back to an env var (tests / non-macOS / CI).
  """

  @doc "Key from the login Keychain `service`, else the `env` var, else nil."
  def get(service, env), do: read(service) || System.get_env(env)

  @doc "Whether a key is available (Keychain or env)."
  def present?(service, env), do: get(service, env) != nil

  @doc """
  Store `key` in the login Keychain under `service`, replacing any existing entry.
  Returns `:ok` or `{:error, output}`.
  """
  def put(service, key) when is_binary(key) do
    case String.trim(key) do
      "" ->
        # Refuse a blank key: never risk wiping a working one for an empty write.
        {:error, "empty key"}

      trimmed ->
        account = System.get_env("USER") || "air-defense"
        # `-U` updates the existing item in place (add-or-replace). Unlike the old
        # delete-then-add, a failed write can never leave the Keychain with no key.
        case System.cmd(
               "security",
               ["add-generic-password", "-U", "-a", account, "-s", service, "-w", trimmed],
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {out, _} -> {:error, String.trim(out)}
        end
    end
  rescue
    _ -> {:error, "keychain unavailable"}
  end

  defp read(service) do
    case System.cmd("security", ["find-generic-password", "-s", service, "-w"],
           stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end
end
