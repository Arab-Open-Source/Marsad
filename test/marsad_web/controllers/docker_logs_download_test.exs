defmodule MarsadWeb.DockerLogsDownloadTest do
  use MarsadWeb.ConnCase, async: false

  alias Marsad.Fleet
  alias MarsadWeb.FileSessionStub

  setup %{conn: conn} do
    {:ok, server} =
      Fleet.create_server(%{
        name: "dllogs-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 22,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    stub = start_stub(server.id, 5)
    on_exit(fn -> if Process.alive?(stub), do: GenServer.stop(stub, :normal, 1000) end)

    {:ok, conn: log_in_admin(conn), server: server, stub: stub}
  end

  defp start_stub(server_id, attempts) do
    kill_registry(server_id)
    wait_free(server_id)

    case FileSessionStub.start_link(server_id: server_id, owner: self()) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, _}} when attempts > 1 ->
        Process.sleep(50)
        start_stub(server_id, attempts - 1)

      {:error, reason} ->
        flunk("could not start file session stub: #{inspect(reason)}")
    end
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
  end

  defp wait_free(id, deadline \\ System.monotonic_time(:millisecond) + 2000) do
    case Registry.lookup(Marsad.Fleet.Registry, id) do
      [] ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          :ok
        else
          Process.sleep(20)
          wait_free(id, deadline)
        end
    end
  end

  test "redirects guests to login", %{conn: _conn} do
    # Setup already created the admin, so a raw conn is a guest post-setup.
    conn = Phoenix.ConnTest.build_conn() |> get(~p"/docker/logs/download?server_id=1&name=web")
    assert redirected_to(conn) == "/login"
  end

  test "rejects bad params", %{conn: conn} do
    assert get(conn, ~p"/docker/logs/download") |> text_response(400) =~ "Missing"

    assert get(conn, ~p"/docker/logs/download?server_id=abc&name=web") |> text_response(400) =~
             "invalid"

    assert get(conn, ~p"/docker/logs/download?server_id=999999&name=web") |> text_response(400) =~
             "invalid"

    assert get(conn, ~p"/docker/logs/download?server_id=1&name=bad+name") |> text_response(400) =~
             "invalid"
  end

  test "unreachable server yields 404", %{conn: conn} do
    {:ok, server} =
      Fleet.create_server(%{
        name: "unreach-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 1,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    conn = get(conn, ~p"/docker/logs/download?server_id=#{server.id}&name=web")
    assert text_response(conn, 404) =~ "failed"
  end

  test "streams logs as an attachment", %{conn: conn, stub: stub, server: server} do
    FileSessionStub.enqueue(stub, {:ok, %{stdout: "line1\nline2\n", stderr: "", status: 0}})

    conn = get(conn, ~p"/docker/logs/download?server_id=#{server.id}&name=web&timestamps=true")
    assert response(conn, 200) == "line1\nline2\n"
    assert response_content_type(conn, :text)
    assert get_resp_header(conn, "content-disposition") |> hd() =~ "web.log"
  end
end
