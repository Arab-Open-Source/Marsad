defmodule MarsadWeb.AuthController do
  use MarsadWeb, :controller

  import Phoenix.Component, only: [to_form: 1, to_form: 2]

  alias Marsad.Accounts
  alias Marsad.Accounts.Admin

  plug MarsadWeb.Plugs.RedirectIfAdmin
       when action in [:setup, :create_setup, :login, :create_login]

  @doc """
  First-time registration: username + password become the admin account
  used for every later sign-in (changeable from Settings).
  """
  def setup(conn, _params) do
    if Accounts.admin_exists?() do
      redirect(conn, to: "/login")
    else
      changeset = Accounts.change_registration(%Admin{})
      render(conn, :setup, form: to_form(changeset))
    end
  end

  def create_setup(conn, params) do
    attrs = admin_params(params)

    case Accounts.register_admin(attrs) do
      {:ok, admin} ->
        conn
        |> put_session(:admin_id, admin.id)
        |> configure_session(renew: true)
        |> put_flash(:info, "Welcome to Marsad OS")
        |> redirect(to: "/")

      {:error, :already_setup} ->
        redirect(conn, to: "/login")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :setup, form: to_form(%{changeset | action: :insert}))
    end
  end

  def login(conn, _params) do
    if Accounts.admin_exists?() do
      render(conn, :login, form: to_form(%{"username" => ""}, as: :admin), error: nil)
    else
      redirect(conn, to: "/setup")
    end
  end

  def create_login(conn, params) do
    creds = admin_params(params)
    username = creds["username"] || ""
    password = creds["password"] || ""

    case Accounts.authenticate(username, password) do
      {:ok, admin} ->
        conn
        |> put_session(:admin_id, admin.id)
        |> configure_session(renew: true)
        |> put_flash(:info, "Signed in")
        |> redirect(to: "/")

      {:error, _} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render(:login,
          form: to_form(%{"username" => username}, as: :admin),
          error: "Invalid username or password"
        )
    end
  end

  # Accepts both nested (`admin[username]`) and flat (`username`) params so a
  # missing/renamed form scope can never raise ActionClauseError.
  defp admin_params(%{"admin" => %{} = nested}), do: nested
  defp admin_params(%{"admin" => _}), do: %{}
  defp admin_params(params) when is_map(params), do: Map.take(params, ["username", "password"])
end
