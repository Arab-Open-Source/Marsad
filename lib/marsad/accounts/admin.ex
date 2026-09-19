defmodule Marsad.Accounts.Admin do
  @moduledoc "Local administrator account (single-admin, self-hosted)."
  use Ecto.Schema
  import Ecto.Changeset

  schema "admins" do
    field :username, :string
    field :password, :string, virtual: true
    field :password_hash, :string

    timestamps(type: :utc_datetime)
  end

  @doc false
  def registration_changeset(admin, attrs) do
    admin
    |> cast(attrs, [:username, :password])
    |> validate_required([:username, :password])
    |> validate_length(:username, min: 3, max: 64)
    |> validate_format(:username, ~r/\A[\w@.\-+]+\z/,
      message: "may contain letters, numbers and @._-+"
    )
    |> validate_length(:password, min: 8, max: 128)
    |> unique_constraint(:username)
    |> put_password_hash()
  end

  @doc false
  def password_changeset(admin, attrs) do
    admin
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8, max: 128)
    |> put_password_hash()
  end

  defp put_password_hash(%Ecto.Changeset{valid?: true, changes: %{password: password}} = cs) do
    put_change(cs, :password_hash, Marsad.Accounts.Password.hash(password))
  end

  defp put_password_hash(cs), do: cs
end
