defmodule Marsad.Accounts do
  @moduledoc """
  Local admin authentication (first-time setup + login).

  Password hashing lives in `Marsad.Accounts.Password`
  (PBKDF2-HMAC-SHA256 via OTP `:crypto`, no extra dependency).
  """

  import Ecto.Query, warn: false

  alias Marsad.Accounts.Admin
  alias Marsad.Accounts.Password
  alias Marsad.Repo

  def count_admins, do: Repo.aggregate(Admin, :count, :id)

  def admin_exists?, do: count_admins() > 0

  def get_admin(id), do: Repo.get(Admin, id)

  def get_admin_by_username(username) when is_binary(username) do
    Repo.get_by(Admin, username: String.trim(username))
  end

  def get_admin_by_username(_), do: nil

  def first_admin, do: Repo.one(from a in Admin, order_by: [asc: a.id], limit: 1)

  def change_registration(%Admin{} = admin, attrs \\ %{}) do
    Admin.registration_changeset(admin, attrs)
  end

  def change_password(%Admin{} = admin, attrs \\ %{}) do
    Admin.password_changeset(admin, attrs)
  end

  @doc "Creates the admin account. Fails when an admin already exists (single-admin mode)."
  def register_admin(attrs) do
    if admin_exists?() do
      {:error, :already_setup}
    else
      %Admin{}
      |> Admin.registration_changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc "Verifies username + password. Returns `{:ok, admin}` or `{:error, :invalid_credentials}`."
  def authenticate(username, password)
      when is_binary(username) and is_binary(password) do
    case get_admin_by_username(username) do
      nil ->
        # Constant-time-ish dummy check to avoid user enumeration via timing.
        Password.dummy_verify()
        {:error, :invalid_credentials}

      admin ->
        if Password.verify(password, admin.password_hash) do
          {:ok, admin}
        else
          {:error, :invalid_credentials}
        end
    end
  end

  def authenticate(_, _), do: {:error, :invalid_credentials}

  @doc "Changes an admin password (used from Settings)."
  def update_password(%Admin{} = admin, attrs) do
    admin
    |> Admin.password_changeset(attrs)
    |> Repo.update()
  end

  @doc "Resets auth: deletes all admins so setup can run again."
  def reset_all do
    Repo.delete_all(Admin)
    :ok
  end
end
