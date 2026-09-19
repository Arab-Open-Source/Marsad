defmodule Marsad.Fleet.SftpOpsTest do
  @moduledoc "Fleet sftp/exec wrappers + Files.search success via stub."
  use Marsad.DataCase, async: false

  alias Marsad.Fleet
  alias Marsad.Fleet.Services
  alias Marsad.Fleet.SysInfo
  alias Marsad.Files
  alias MarsadWeb.FileSessionStub

  setup do
    {:ok, server} =
      Fleet.create_server(%{
        name: "sftp-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 22,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    case Registry.lookup(Marsad.Fleet.Registry, server.id) do
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

    wait_free(server.id)

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

          wait_free(server.id)
          FileSessionStub.start_link(server_id: server.id, owner: self())
      end

    on_exit(fn -> if Process.alive?(stub), do: GenServer.stop(stub, :normal, 1000) end)
    %{server: server, stub: stub}
  end

  defp wait_free(id, deadline \\ System.monotonic_time(:millisecond) + 2000) do
    case Registry.lookup(Marsad.Fleet.Registry, id) do
      [] ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) > deadline,
          do: :ok,
          else: Process.sleep(20) && wait_free(id, deadline)
    end
  end

  defp exec_reply(stdout, status \\ 0), do: {:ok, %{stdout: stdout, stderr: "", status: status}}
  defp sftp_ok(value), do: {:ok, {:ok, value}}

  test "exec passes through", %{stub: stub, server: server} do
    FileSessionStub.enqueue(stub, exec_reply("hi\n"))
    assert {:ok, %{stdout: "hi\n"}} = Fleet.exec(server.id, "echo hi")
  end

  test "sftp wrappers pass through", %{stub: stub, server: server} do
    # Tuple-returning adapter fns are double-wrapped by with_sftp;
    # bare-:ok fns (write/upload/mkdir/delete) are single-wrapped.
    FileSessionStub.enqueue(stub, sftp_ok("chunk"))
    assert {:ok, "chunk"} = Fleet.read_file(server.id, "/a", 10)

    FileSessionStub.enqueue(stub, {:ok, :ok})
    assert :ok = Fleet.write_file(server.id, "/a", "data")

    FileSessionStub.enqueue(stub, {:ok, :ok})
    assert :ok = Fleet.upload_file(server.id, "/a", "/tmp/x")

    FileSessionStub.enqueue(stub, {:ok, :ok})
    assert :ok = Fleet.make_dir(server.id, "/a/b")

    FileSessionStub.enqueue(stub, {:ok, :ok})
    assert :ok = Fleet.delete_path(server.id, "/a")

    FileSessionStub.enqueue(stub, {:ok, :ok})
    assert :ok = Fleet.delete_path(server.id, "/a", true)

    FileSessionStub.enqueue(stub, sftp_ok("/root"))
    assert {:ok, "/root"} = Fleet.home_dir(server.id)
  end

  test "files.search_remote_files parses find output", %{stub: stub, server: server} do
    FileSessionStub.enqueue(stub, sftp_ok("/root"))
    FileSessionStub.enqueue(stub, exec_reply("/root/app.conf|100|1700000000.0\nbad-line\n"))

    assert [%{name: "app.conf", path: "/root/app.conf", size: 100}] =
             Files.search_remote_files(server.id, "conf")
  end

  test "services docker/systemd/nginx success paths", %{stub: stub, server: server} do
    FileSessionStub.enqueue(stub, exec_reply("web\n", 0))
    assert {:ok, "web"} = Services.docker_action(server.id, "start", "web")

    FileSessionStub.enqueue(stub, exec_reply("log line\n"))
    assert {:ok, "log line\n"} = Services.docker_logs(server.id, "web")

    FileSessionStub.enqueue(stub, exec_reply(~s([{"Id":"abc","Name":"web"}]\n)))
    assert {:ok, %{"Name" => "web"}} = Services.docker_inspect(server.id, "web")

    FileSessionStub.enqueue(stub, exec_reply("stats\n"))
    assert {:ok, _} = Services.docker_stats(server.id)

    FileSessionStub.enqueue(stub, exec_reply("", 0))
    assert {:ok, ""} = Services.systemd_action(server.id, "restart", "nginx.service")

    FileSessionStub.enqueue(stub, exec_reply("logs\n"))
    assert {:ok, "logs\n"} = Services.systemd_logs(server.id, "nginx.service")

    FileSessionStub.enqueue(stub, exec_reply("test is successful\n"))
    assert {:ok, _} = Services.nginx_action(server.id, "test")

    FileSessionStub.enqueue(stub, exec_reply("", 0))
    assert {:ok, _} = Services.nginx_action(server.id, "reload")

    FileSessionStub.enqueue(stub, exec_reply("full config\n"))
    assert {:ok, "full config\n"} = Services.nginx_config(server.id)

    FileSessionStub.enqueue(stub, exec_reply("err\n"))
    assert {:ok, "err\n"} = Services.nginx_error_log(server.id)
  end

  test "sysinfo legacy fallback when batch is garbage", %{stub: stub, server: server} do
    # Batched call returns garbage -> fallback does 7 execs.
    FileSessionStub.enqueue(stub, exec_reply("garbage-no-markers\n"))
    FileSessionStub.enqueue(stub, exec_reply("0.50 0.30 0.20 1/1 1\n"))
    FileSessionStub.enqueue(stub, exec_reply("4\n"))
    FileSessionStub.enqueue(stub, exec_reply("Mem: 8000 2000 6000\n"))

    FileSessionStub.enqueue(
      stub,
      exec_reply("Filesystem 1M Use Avail Use% Mount\n/dev/sda1 20000 5000 15000 25% /\n")
    )

    FileSessionStub.enqueue(
      stub,
      exec_reply("Filesystem 1M Use Avail Use% Mount\n/dev/sda1 20000 5000 15000 25% /\n")
    )

    FileSessionStub.enqueue(stub, exec_reply("\n"))
    FileSessionStub.enqueue(stub, exec_reply("up 1 day\nhost-legacy\n6.0\n"))

    assert {:ok, snap} = SysInfo.fetch(server.id)
    assert snap.hostname == "host-legacy"
  end
end
