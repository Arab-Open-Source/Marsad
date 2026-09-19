defmodule MarsadWeb.Plugs.RequireAdmin do
  @moduledoc false
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    # Fresh install (no admin yet) goes straight to first-time setup.
    unless Marsad.Accounts.admin_exists?() do
      conn |> redirect(to: "/setup") |> halt()
    else
      case get_session(conn, :admin_id) do
        nil ->
          conn |> redirect(to: "/login") |> halt()

        admin_id ->
          case Marsad.Accounts.get_admin(admin_id) do
            nil ->
              conn |> configure_session(drop: true) |> redirect(to: "/login") |> halt()

            _admin ->
              conn
          end
      end
    end
  end
end

defmodule MarsadWeb.Plugs.RedirectIfAdmin do
  @moduledoc false
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :admin_id) do
      nil ->
        conn

      admin_id ->
        case Marsad.Accounts.get_admin(admin_id) do
          nil -> conn
          _admin -> conn |> redirect(to: "/") |> halt()
        end
    end
  end
end
