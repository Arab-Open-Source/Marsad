defmodule Marsad.Repo.Migrations.CreateMetricsSnapshots do
  use Ecto.Migration

  def change do
    create table(:metrics_snapshots) do
      add :server_id, references(:servers, on_delete: :delete_all), null: false
      add :load1, :float, null: false
      add :load5, :float, null: false
      add :load15, :float, null: false
      add :cores, :integer, null: false
      add :mem_total_mb, :integer, null: false
      add :mem_used_mb, :integer, null: false
      add :disk_total_mb, :integer, null: false
      add :disk_used_mb, :integer, null: false
      add :disk_pct, :integer, null: false
      add :disks, :text
      add :cpu_per_core, :text
      add :net_rx_mb, :float
      add :net_tx_mb, :float

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:metrics_snapshots, [:server_id, :inserted_at])
    create index(:metrics_snapshots, [:inserted_at])
  end
end
