defmodule Marsad.SettingsExtraTest do
  use Marsad.DataCase, async: false

  alias Marsad.Settings

  test "put/get round-trip and appearance fallbacks" do
    assert Settings.get("missing-key", "dflt") == "dflt"
    {:ok, _} = Settings.put("theme_mode", "light")
    assert Settings.get("theme_mode") == "light"

    assert %{mode: "light"} = Settings.appearance()

    {:ok, _} = Settings.put("theme_mode", "weird")
    {:ok, _} = Settings.put("accent", "nope")
    assert %{mode: "dark", accent: "ocean"} = Settings.appearance()
  end

  test "metrics_interval clamps and rejects" do
    assert Settings.metrics_interval() in [5000, 15_000]

    {:ok, _} = Settings.put("metrics_interval", "not-a-number")
    assert Settings.metrics_interval() == 15_000

    {:ok, _} = Settings.put("metrics_interval", "1000")
    assert Settings.metrics_interval() == 15_000

    {:ok, _} = Settings.put_metrics_interval(10_000)
    assert Settings.metrics_interval() == 10_000
    assert {:error, :invalid_interval} = Settings.put_metrics_interval(100)
  end

  test "accents and modes enumerate" do
    assert Map.has_key?(Settings.accents(), "ocean")
    assert "dark" in Settings.theme_modes()
  end
end

defmodule Marsad.Fleet.CredentialVaultExtraTest do
  use ExUnit.Case, async: true

  alias Marsad.Fleet.CredentialVault

  test "tampered and garbage payloads fail" do
    sealed = CredentialVault.seal("hello")
    assert {:ok, "hello"} = CredentialVault.open(sealed)
    assert :error = CredentialVault.open(sealed <> "x")
    assert :error = CredentialVault.open("not-a-payload")
    assert :error = CredentialVault.open(nil)
  end
end
