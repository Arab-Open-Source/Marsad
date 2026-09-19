defmodule Marsad.Fleet.RemoteSuccessTest do
  @moduledoc "Success paths for Fleet/Services/SysInfo via FileSessionStub (no real SSH)."
  use Marsad.DataCase, async: false

  alias Marsad.Fleet
  alias Marsad.Fleet.Services
  alias Marsad.Fleet.SysInfo
  alias MarsadWeb.FileSessionStub

  setup do
    {:ok, server} =
      Fleet.create_server(%{
        name: "stub-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 22,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    kill_registry(server.id)

    {:ok, stub} =
      case FileSessionStub.start_link(server_id: server.id, owner: self()) do
        {:ok, pid} ->
          {:ok, pid}

        {:error, {:already_started, pid}} ->
          try do
            if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1000)
          catch
            :exit, _ -> :ok
          end

          wait_registry_free(server.id)
          FileSessionStub.start_link(server_id: server.id, owner: self())
      end

    on_exit(fn -> if Process.alive?(stub), do: GenServer.stop(stub, :normal, 1000) end)

    %{server: server, stub: stub}
  end

  defp kill_registry(server_id) do
    case Registry.lookup(Marsad.Fleet.Registry, server_id) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(Marsad.Fleet.DynamicSupervisor, pid)

        try do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1000)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end

    wait_registry_free(server_id)
  end

  defp wait_registry_free(server_id, deadline \\ System.monotonic_time(:millisecond) + 2000) do
    case Registry.lookup(Marsad.Fleet.Registry, server_id) do
      [] ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          :ok
        else
          Process.sleep(20)
          wait_registry_free(server_id, deadline)
        end
    end
  end

  defp exec_reply(stdout, status \\ 0),
    do: {:ok, %{stdout: stdout, stderr: "", status: status}}

  test "test_connection ok", %{stub: stub, server: server} do
    FileSessionStub.enqueue(stub, exec_reply("marsad-ok\n"))
    assert :ok = Fleet.test_connection(server.id)
  end

  test "docker_containers parses stubbed ps", %{stub: stub, server: server} do
    FileSessionStub.enqueue(
      stub,
      exec_reply(
        ~s({"ID":"abc123","Names":"web","Image":"nginx","State":"running","Status":"Up","Ports":"80"}\n)
      )
    )

    assert {:ok, [%{name: "web"}]} = Services.docker_containers(server.id)
  end

  test "docker_unavailable maps daemon errors", %{stub: stub, server: server} do
    FileSessionStub.enqueue(stub, exec_reply("Cannot connect to the Docker daemon\n"))
    assert {:error, :docker_unavailable} = Services.docker_containers(server.id)
  end

  test "systemd_units parses stubbed list", %{stub: stub, server: server} do
    FileSessionStub.enqueue(
      stub,
      exec_reply("cron.service loaded active running Cron\n", 0)
    )

    assert {:ok, [%{unit: "cron.service"}]} = Services.systemd_units(server.id)
  end

  test "nginx_status combines active + config test", %{stub: stub, server: server} do
    FileSessionStub.enqueue(stub, exec_reply("active\n"))

    FileSessionStub.enqueue(
      stub,
      exec_reply("nginx: the configuration file syntax is ok\ntest is successful\n")
    )

    assert {:ok, %{active: "active", test_ok?: true}} = Services.nginx_status(server.id)
  end

  test "sysinfo fetch uses single batched round-trip", %{stub: stub, server: server} do
    batched = """
    __MARSAD_LOAD__
    0.50 0.30 0.20 1/100 1
    __MARSAD_CORES__
    4
    __MARSAD_MEM__
                  total        used        free
    Mem:           8000        2000        6000
    __MARSAD_DFALL__
    Filesystem 1M-blocks Used Available Use% Mounted on
    /dev/sda1  20000  5000  15000  25% /
    __MARSAD_DF__
    Filesystem 1M-blocks Used Available Use% Mounted on
    /dev/sda1  20000  5000  15000  25% /
    __MARSAD_NET__
    Inter-|   Receive | Transmit
     face |bytes
      eth0: 1048576 0 0 0 0 0 0 0 2097152 0 0 0 0 0 0 0
    __MARSAD_MISC__
    up 2 days
    stub-host
    6.8.0
    __MARSAD_END__
    """

    FileSessionStub.enqueue(stub, exec_reply(batched))
    assert {:ok, snap} = SysInfo.fetch(server.id)
    assert snap.cores == 4
    assert snap.hostname == "stub-host"
    assert snap.net_rx_mb == 1.0
  end

  test "top_processes parses stubbed ps", %{stub: stub, server: server} do
    FileSessionStub.enqueue(stub, exec_reply("  1 init 0.0 0.1\n"))
    assert {:ok, [%{pid: 1}]} = SysInfo.top_processes(server.id)
  end

  test "list_dir via sftp stub", %{stub: stub, server: server} do
    FileSessionStub.enqueue(stub, {:ok, {:ok, [%{name: "a", type: :file}]}})
    assert {:ok, [%{name: "a"}]} = Fleet.list_dir(server.id, "/root")
  end
end
