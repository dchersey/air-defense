defmodule LgaPredictor.KeychainTest do
  use ExUnit.Case

  alias LgaPredictor.Keychain

  describe "put/2" do
    # A blank key must be rejected *before* any `security` call — the old delete-then-add
    # could wipe a working key if the write was empty/failed. This guard returns early, so
    # it never touches the real login Keychain (safe in CI and won't prompt).
    test "refuses a blank key so it can't clobber an existing one" do
      assert Keychain.put("air-defense-test-should-not-exist", "") == {:error, "empty key"}
      assert Keychain.put("air-defense-test-should-not-exist", "   \n") == {:error, "empty key"}
    end
  end
end
