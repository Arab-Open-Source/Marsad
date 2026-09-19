defmodule Marsad.Metrics.SnapshotTest do
  use ExUnit.Case, async: true

  alias Marsad.Metrics.Snapshot

  test "changeset requires core fields" do
    assert %Ecto.Changeset{valid?: false} = Snapshot.changeset(%Snapshot{}, %{})

    assert %Ecto.Changeset{valid?: true} =
             Snapshot.changeset(%Snapshot{}, %{
               server_id: 1,
               load1: 0.5,
               cores: 2,
               mem_total_mb: 512,
               mem_used_mb: 100
             })
  end
end

defmodule Marsad.AuditLogTest do
  use ExUnit.Case, async: true

  alias Marsad.AuditLog

  test "changeset requires server and action, caps lengths" do
    assert %Ecto.Changeset{valid?: false} = AuditLog.changeset(%AuditLog{}, %{})

    ok =
      AuditLog.changeset(%AuditLog{}, %{server_id: 1, action: "start", container: "web"})

    assert ok.valid?

    long = String.duplicate("x", 300)
    bad = AuditLog.changeset(%AuditLog{}, %{server_id: 1, action: "a", container: long})
    refute bad.valid?
  end
end

defmodule Marsad.Fleet.ServerTest do
  use ExUnit.Case, async: true

  alias Marsad.Fleet.Server

  test "changeset validates required, auth type, port and host" do
    assert %Ecto.Changeset{valid?: false} = Server.changeset(%Server{}, %{})

    good =
      Server.changeset(%Server{}, %{
        name: "prod-1",
        host: "example.com",
        username: "root",
        auth_type: "password",
        port: 22
      })

    assert good.valid?
    assert Server.auth_types() == ["password", "key"]

    bad_auth =
      Server.changeset(%Server{}, %{name: "n", host: "h", username: "u", auth_type: "token"})

    refute bad_auth.valid?

    bad_port =
      Server.changeset(%Server{}, %{
        name: "n",
        host: "h",
        username: "u",
        auth_type: "password",
        port: 99_999
      })

    refute bad_port.valid?

    bad_host =
      Server.changeset(%Server{}, %{
        name: "n",
        host: "bad host!",
        username: "u",
        auth_type: "password"
      })

    refute bad_host.valid?
  end
end
