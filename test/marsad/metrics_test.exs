defmodule Marsad.MetricsTest do
  use Marsad.DataCase, async: false

  import Ecto.Query, warn: false

  alias Marsad.Metrics

  defp create_server do
    {:ok, server} =
      Marsad.Fleet.create_server(%{
        name: "metrics-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 22,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    server
  end

  defp snapshot_attrs(server_id, extra \\ %{}) do
    Map.merge(
      %{
        server_id: server_id,
        load1: 1.5,
        load5: 1.0,
        load15: 0.5,
        cores: 2,
        mem_total_mb: 1000,
        mem_used_mb: 250,
        disk_total_mb: 10_000,
        disk_used_mb: 2500,
        disk_pct: 25
      },
      extra
    )
  end

  test "create/list/prune snapshots" do
    server = create_server()

    assert {:error, %Ecto.Changeset{}} = Metrics.create_snapshot(%{server_id: nil})
    assert {:ok, _} = Metrics.create_snapshot(snapshot_attrs(server.id))
    assert {:ok, _} = Metrics.create_snapshot(snapshot_attrs(server.id, %{load1: 3.0}))

    assert length(Metrics.list_snapshots(server.id)) == 2
    assert length(Metrics.list_snapshots(-999)) == 0

    # Old rows are pruned (backdate via update_all since changeset drops inserted_at).
    server2 = create_server()
    {:ok, old} = Metrics.create_snapshot(snapshot_attrs(server2.id))

    cutoff = DateTime.add(DateTime.utc_now(), -200_000, :second)

    {1, _} =
      Marsad.Repo.update_all(
        from(s in Marsad.Metrics.Snapshot, where: s.id == ^old.id),
        set: [inserted_at: cutoff]
      )

    assert {1, _} = Metrics.prune_old(48)
    assert Metrics.list_snapshots(server2.id) == []
  end

  test "chart_data handles empty and zero-memory snapshots" do
    assert %{labels: [], datasets: [_ | _]} = Metrics.chart_data(123_456_789, 1)

    server = create_server()

    {:ok, _} =
      Metrics.create_snapshot(
        snapshot_attrs(server.id, %{mem_total_mb: 100, mem_used_mb: 0, disk_pct: 0})
      )

    data = Metrics.chart_data(server.id, 1)
    assert length(data.labels) == 1
    [_cpu, mem, disk] = data.datasets
    assert mem.data == [0]
    assert disk.data == [0]
  end

  test "chart_data caps CPU and formats multi-day labels" do
    server = create_server()
    {:ok, _} = Metrics.create_snapshot(snapshot_attrs(server.id, %{load1: 100.0, cores: 1}))
    %{datasets: [cpu | _]} = Metrics.chart_data(server.id, 1)
    assert hd(cpu.data) == 200

    data = Metrics.chart_data(server.id, 48)
    assert length(data.labels) == 1
    assert hd(data.labels) =~ "/"
  end
end
