defmodule Marsad.Fleet.ServerSessionTest do
  use Marsad.DataCase, async: false

  alias Marsad.Fleet
  alias Marsad.Fleet.ServerSession

  setup do
    {:ok, server} =
      Fleet.create_server(%{
        name: "sess-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 1,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    on_exit(fn ->
      case Registry.lookup(Marsad.Fleet.Registry, server.id) do
        [{pid, _}] ->
          DynamicSupervisor.terminate_child(Marsad.Fleet.DynamicSupervisor, pid)

        [] ->
          :ok
      end
    end)

    %{server: server}
  end

  test "status is disconnected before any use", %{server: server} do
    assert %{connected?: false} = ServerSession.status(server.id)
  end

  test "exec and sftp surface connection errors without crashing", %{server: server} do
    assert :ok = Fleet.ensure_session(server.id)
    assert {:error, _} = ServerSession.exec(server.id, "echo hi", 500)
    assert {:error, _} = ServerSession.sftp(server.id, fn _ -> :ok end)

    # Failures are tracked, connection stays down.
    assert %{connected?: false} = ServerSession.status(server.id)
  end

  test "via registry names are unique per server", %{server: server} do
    assert ServerSession.via(server.id) ==
             {:via, Registry, {Marsad.Fleet.Registry, server.id}}
  end
end
