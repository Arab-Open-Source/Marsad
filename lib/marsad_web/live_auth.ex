defmodule MarsadWeb.LiveAuth do
  @moduledoc "LiveView `on_mount` hooks enforcing local admin auth."
  import Phoenix.LiveView
  import Phoenix.Component

  def on_mount(:ensure, _params, session, socket) do
    # Fresh install (no admin yet) goes straight to first-time setup.
    unless Marsad.Accounts.admin_exists?() do
      {:halt, redirect(socket, to: "/setup")}
    else
      case session["admin_id"] do
        nil ->
          {:halt, redirect(socket, to: "/login")}

        admin_id ->
          case Marsad.Accounts.get_admin(admin_id) do
            nil -> {:halt, redirect(socket, to: "/login")}
            admin -> {:cont, assign(socket, :current_admin, admin)}
          end
      end
    end
  end

  def on_mount(:guest, _params, session, socket) do
    case session["admin_id"] do
      nil ->
        {:cont, socket}

      admin_id ->
        case Marsad.Accounts.get_admin(admin_id) do
          nil -> {:cont, socket}
          _admin -> {:halt, redirect(socket, to: "/")}
        end
    end
  end
end
