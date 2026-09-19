defmodule Marsad.SettingsTest do
  use Marsad.DataCase, async: false

  alias Marsad.Settings

  test "put/2 and get/2 round-trip, put overwrites" do
    assert {:ok, _} = Settings.put("theme_mode", "light")
    assert Settings.get("theme_mode") == "light"

    assert {:ok, _} = Settings.put("theme_mode", "dark")
    assert Settings.get("theme_mode") == "dark"
  end

  test "get/2 returns default when absent" do
    assert Settings.get("nope", "fallback") == "fallback"
  end

  test "appearance/0 returns curated defaults on empty DB" do
    assert %{mode: "dark", accent: "ocean", hex: "#0369A1", ink: "#FFFFFF"} =
             Settings.appearance()
  end

  test "appearance/0 honors stored values and rejects unknown ones" do
    assert {:ok, _} = Settings.put("theme_mode", "light")
    assert {:ok, _} = Settings.put("accent", "rose")
    assert %{mode: "light", accent: "rose", hex: "#BE123C"} = Settings.appearance()

    assert {:ok, _} = Settings.put("theme_mode", "neon")
    assert {:ok, _} = Settings.put("accent", "hotpink")
    assert %{mode: "dark", accent: "ocean"} = Settings.appearance()
  end
end
