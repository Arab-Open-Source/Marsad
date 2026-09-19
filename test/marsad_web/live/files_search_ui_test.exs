defmodule MarsadWeb.FilesSearchUiTest do
  use MarsadWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Marsad.Fleet
  alias MarsadWeb.FileSessionStub

  setup do
    {:ok, server} =
      Fleet.create_server(%{
        name: "search-ui-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 22,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    stub = start_stub(server.id, 5)

    on_exit(fn -> if Process.alive?(stub), do: GenServer.stop(stub, :normal, 1000) end)
    %{server: server, stub: stub}
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
        # Supervised real sessions restart on plain stop — terminate first.
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

  defp enqueue(stub, replies), do: Enum.each(replies, &FileSessionStub.enqueue(stub, &1))
  defp sftp(value), do: {:ok, {:ok, value}}

  defp wait_until(fun, timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk("condition not met in time")
      true -> Process.sleep(50) && do_wait(fun, deadline)
    end
  end

  defp open_files(view, stub) do
    enqueue(stub, [
      sftp("/root"),
      sftp([%{name: "docs", type: :dir, size: 0, mtime: 0}])
    ])

    view |> element("#icon-files") |> render_click()
    wait_until(fn -> has_element?(view, "#files-list") end)
  end

  test "truncated badge appears when results exceed the limit", %{conn: conn, stub: stub} do
    conn = MarsadWeb.ConnCase.log_in_admin(conn)
    {:ok, view, _} = live(conn, ~p"/")
    open_files(view, stub)

    enqueue(stub, [
      sftp("/root"),
      {:ok,
       %{
         stdout: """
         f|1|1700000000|/root/b1.conf
         f|1|1700000000|/root/b2.conf
         """
       }}
    ])

    view |> render_change("files-filter", %{"filter" => "b limit:1"})
    wait_until(fn -> has_element?(view, "#file-b1\\.conf") end)

    assert has_element?(view, "span", "truncated")
    refute has_element?(view, "#file-b2\\.conf")
  end

  test "dropping a chip re-runs the search without it", %{conn: conn, stub: stub} do
    conn = MarsadWeb.ConnCase.log_in_admin(conn)
    {:ok, view, _} = live(conn, ~p"/")
    open_files(view, stub)

    enqueue(stub, [
      sftp("/root"),
      {:ok, %{stdout: "f|1|1700000000|/root/deep.conf\n"}}
    ])

    view |> render_change("files-filter", %{"filter" => "deep ext:conf"})
    wait_until(fn -> has_element?(view, "#file-deep\\.conf") end)
    assert has_element?(view, "[phx-click=files-drop-token]")

    enqueue(stub, [
      sftp("/root"),
      {:ok, %{stdout: "f|1|1700000000|/root/deep.conf\n"}}
    ])

    view |> element("[phx-value-token=\"ext:conf\"]") |> render_click()
    wait_until(fn -> render(view) =~ "value=\"deep\"" end)
    refute has_element?(view, "[phx-value-token=\"ext:conf\"]")
    assert has_element?(view, "[phx-value-token=\"deep\"]")
  end

  test "remote hits show their full path", %{conn: conn, stub: stub} do
    conn = MarsadWeb.ConnCase.log_in_admin(conn)
    {:ok, view, _} = live(conn, ~p"/")
    open_files(view, stub)

    enqueue(stub, [
      sftp("/root"),
      {:ok, %{stdout: "f|1|1700000000|/etc/nginx/deep.conf\n"}}
    ])

    view |> render_change("files-filter", %{"filter" => "deep"})
    wait_until(fn -> has_element?(view, "#file-deep\\.conf") end)

    html = render(view)
    assert html =~ "/etc/nginx/deep.conf"
  end
end
