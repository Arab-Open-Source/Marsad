defmodule Marsad.Fleet.Server do
  @moduledoc "An SSH-managed VPS/server in the fleet."
  use Ecto.Schema
  import Ecto.Changeset

  @auth_types ~w(password key)

  schema "servers" do
    field :name, :string
    field :host, :string
    field :port, :integer, default: 22
    field :username, :string
    field :auth_type, :string, default: "password"
    # Encrypted at rest via `Marsad.Fleet.CredentialVault`.
    # Holds a password, or a PEM private key / key-file path for `key` auth.
    field :secret_encrypted, :string
    field :host_fingerprint, :string
    field :status, :string, default: "unknown"
    field :last_seen_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(server, attrs) do
    server
    |> cast(attrs, [
      :name,
      :host,
      :port,
      :username,
      :auth_type,
      :secret_encrypted,
      :host_fingerprint,
      :status,
      :last_seen_at
    ])
    |> validate_required([:name, :host, :username, :auth_type])
    |> validate_inclusion(:auth_type, @auth_types)
    |> validate_number(:port, greater_than: 0, less_than: 65_536)
    |> validate_format(:host, ~r/^[a-zA-Z0-9.\-_]+$/, message: "must be a hostname or IP")
  end

  @doc "Auth types supported by the SSH backend."
  def auth_types, do: @auth_types
end
