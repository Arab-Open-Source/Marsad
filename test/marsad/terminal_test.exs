defmodule Marsad.TerminalTest do
  use ExUnit.Case, async: true

  alias Marsad.Terminal

  test "prompts and banners render" do
    assert Terminal.demo_prompt() =~ "marsad"
    assert Terminal.welcome_banner(nil) =~ "demo mode"
    assert Terminal.welcome_banner(%{username: "u", host: "h", port: 22}) =~ "u"
    assert Terminal.help_text() =~ "vim"
  end
end
