defmodule Marsad.Metrics do
  import Ecto.Query, warn: false
  alias Marsad.Repo
  alias Marsad.Metrics.Snapshot

  def list_snapshots(server_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)
    hours = Keyword.get(opts, :hours, 24)

    since =
      case Keyword.get(opts, :since) do
        nil -> DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
        dt -> dt
      end

    Snapshot
    |> where([s], s.server_id == ^server_id and s.inserted_at >= ^since)
    |> order_by([s], asc: s.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def create_snapshot(attrs) do
    %Snapshot{}
    |> Snapshot.changeset(attrs)
    |> Repo.insert()
  end

  def prune_old(hours \\ 48) do
    cutoff = DateTime.add(DateTime.utc_now(), -hours * 3600, :second)
    Repo.delete_all(from s in Snapshot, where: s.inserted_at < ^cutoff)
  end

  def chart_data(server_id, hours \\ 24) do
    snapshots = list_snapshots(server_id, hours: hours, limit: 200)

    # Use local time for labels, include date for multi-day views
    label_fmt = if hours <= 24, do: "%H:%M", else: "%m/%d %H:%M"

    %{
      labels:
        Enum.map(snapshots, fn s ->
          Calendar.strftime(DateTime.shift_zone!(s.inserted_at, "Etc/UTC"), label_fmt)
        end),
      datasets: [
        %{
          label: "CPU %",
          data:
            Enum.map(snapshots, fn s ->
              cores = max(s.cores || 1, 1)

              # CPU % as load1/cores*100, capped at 100*core count for burst, but show as % of one core*100
              # For a 3-core system, load 3.0 = 100% (all cores at 100%)
              round(min(s.load1 / cores * 100, 100 * 2))
            end),
          borderColor: "#0ea5e9",
          backgroundColor: "rgba(14,165,233,0.12)",
          tension: 0.35,
          fill: true,
          pointRadius: 0,
          pointHoverRadius: 3
        },
        %{
          label: "Mem %",
          data:
            Enum.map(snapshots, fn s ->
              if s.mem_total_mb > 0, do: round(s.mem_used_mb / s.mem_total_mb * 100), else: 0
            end),
          borderColor: "#10b981",
          backgroundColor: "rgba(16,185,129,0.12)",
          tension: 0.35,
          fill: true,
          pointRadius: 0,
          pointHoverRadius: 3
        },
        %{
          label: "Disk %",
          data: Enum.map(snapshots, & &1.disk_pct),
          borderColor: "#f59e0b",
          backgroundColor: "rgba(245,158,11,0.12)",
          tension: 0.35,
          fill: true,
          pointRadius: 0,
          pointHoverRadius: 3
        }
      ]
    }
  end
end
