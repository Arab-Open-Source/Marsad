defmodule Marsad.Repo.Migrations.AddDockerAuditAndMetrics do
  use Ecto.Migration

  def change do
    create table(:audit_logs) do
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :action, :string, null: false
      add :container, :string
      add :details, :text

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:audit_logs, [:server_id, :inserted_at])
    create index(:audit_logs, [:action])

    alter table(:metrics_snapshots) do
      add :docker_stats, :text
    end
  end
end
