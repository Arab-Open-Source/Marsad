defmodule Marsad.Metrics.Snapshot do
  use Ecto.Schema
  import Ecto.Changeset

  schema "metrics_snapshots" do
    field :server_id, :integer
    field :load1, :float
    field :load5, :float
    field :load15, :float
    field :cores, :integer
    field :mem_total_mb, :integer
    field :mem_used_mb, :integer
    field :disk_total_mb, :integer
    field :disk_used_mb, :integer
    field :disk_pct, :integer
    field :disks, :string
    field :cpu_per_core, :string
    field :net_rx_mb, :float
    field :net_tx_mb, :float
    field :docker_stats, :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, [
      :server_id,
      :load1,
      :load5,
      :load15,
      :cores,
      :mem_total_mb,
      :mem_used_mb,
      :disk_total_mb,
      :disk_used_mb,
      :disk_pct,
      :disks,
      :cpu_per_core,
      :net_rx_mb,
      :net_tx_mb,
      :docker_stats
    ])
    |> validate_required([:server_id, :load1, :cores, :mem_total_mb, :mem_used_mb])
  end
end
