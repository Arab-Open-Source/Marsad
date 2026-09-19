defmodule MarsadWeb.FileDownloadDirTest do
  use MarsadWeb.ConnCase, async: false

  alias Marsad.Fleet
  alias MarsadWeb.FileSessionStub

  setup %{conn: conn} do
    {:ok, server} =
      Fleet.create_server(%{
        name: "dldir-#{System.unique_integer([:positive])}",
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

    {:ok, conn: log_in_admin(conn), server: server, stub: stub}
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

  test "directory downloads as tar.gz", %{conn: conn, stub: stub, server: server} do
    # list_dir (sftp) says it's a directory.
    FileSessionStub.enqueue(stub, {:ok, {:ok, [%{name: "a", type: :file}]}})
    # du says small.
    FileSessionStub.enqueue(stub, {:ok, %{stdout: "1234\n", stderr: "", status: 0}})
    # tar outputs binary archive.
    FileSessionStub.enqueue(stub, {:ok, %{stdout: <<31, 139, 1, 2, 3>>, stderr: "", status: 0}})

    conn = get(conn, ~p"/files/download?server_id=#{server.id}&path=/root/mydir")
    assert response_content_type(conn, :gzip)
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "mydir.tar.gz"
    assert response(conn, 200) == <<31, 139, 1, 2, 3>>
  end

  test "oversized directory is rejected with 413", %{conn: conn, stub: stub, server: server} do
    FileSessionStub.enqueue(stub, {:ok, {:ok, [%{name: "a", type: :file}]}})
    FileSessionStub.enqueue(stub, {:ok, %{stdout: "999999999\n", stderr: "", status: 0}})

    conn = get(conn, ~p"/files/download?server_id=#{server.id}&path=/root/bigdir")
    assert response(conn, 413) =~ "too large"
  end

  test "single file download works", %{conn: conn, stub: stub, server: server} do
    # list_dir fails -> treated as file.
    FileSessionStub.enqueue(stub, {:ok, {:error, :no_such_file}})
    FileSessionStub.enqueue(stub, {:ok, %{stdout: "11\n", stderr: "", status: 0}})
    FileSessionStub.enqueue(stub, {:ok, {:ok, "hello world"}})

    conn = get(conn, ~p"/files/download?server_id=#{server.id}&path=/root/hi.txt")
    assert response(conn, 200) == "hello world"
  end
end
