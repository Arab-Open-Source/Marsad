defmodule Marsad.Repo.Migrations.CreateServers do
  use Ecto.Migration

  def change do
    create table(:servers) do
      add :name, :string, null: false
      add :host, :string, null: false
      add :port, :integer, null: false, default: 22
      add :username, :string, null: false
      add :auth_type, :string, null: false, default: "password"
      add :secret_encrypted, :text
      add :host_fingerprint, :string
      add :status, :string, null: false, default: "unknown"
      add :last_seen_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end
  end
end
