defmodule Marsad.Terminal do
  @moduledoc """
  Terminal copy and demo-mode helpers.

  Server-backed windows run a persistent remote PTY (see
  `Marsad.Fleet.ServerShell`), so prompts, colors, `cd` and fullscreen
  programs all come from the remote shell itself. This module only owns
  the local demo mode (windows without a server) plus shared copy.
  """

  @doc "Fallback prompt when no server is attached."
  def demo_prompt, do: "\e[36mmarsad\e[90m$\e[0m "

  @doc "Banner printed once per demo terminal window."
  def welcome_banner(nil) do
    "\e[1;36mMarsad OS\e[0m · Terminal \e[90m(demo mode — add a server to run remotely).\e[0m\r\nType \e[33mhelp\e[0m for commands.\r\n"
  end

  def welcome_banner(%{username: user, host: host, port: port}) do
    "\e[1;36mMarsad OS\e[0m · Terminal → \e[32m#{user}\e[90m@\e[34m#{host}\e[90m:\e[33m#{port}\e[0m.\r\nA persistent shell opens on this server — vim, top and friends work.\r\n"
  end

  @doc "Local `help` text."
  def help_text do
    "\e[36mCommands:\e[0m a real remote shell — everything works, including vim/nano/top, pipes and `cd`.\r\n\e[36mShortcuts:\e[0m Ctrl+C interrupts · Ctrl+L clears · ↑/↓ history (by the remote shell).\r\n"
  end
end
