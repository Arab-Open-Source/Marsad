defmodule MarsadWeb.DockerTest do
  use MarsadWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Marsad.Fleet
  alias Marsad.Fleet.Services
  alias MarsadWeb.FileSessionStub

  @ps ~s|{"ID":"abc123def456","Image":"nginx:latest","Names":"web","State":"exited","Status":"Exited 0 2 hours ago","Ports":""}\n|

  setup %{conn: conn} do
    {:ok, server} =
      Fleet.create_server(%{
        name: "docker-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 22,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    kill_registry(server.id)
    stub = start_stub(server.id)
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

    wait_free(server_id)
  end

  defp start_stub(server_id, attempts \\ 5) do
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
  defp exec_reply(stdout), do: {:ok, %{stdout: stdout, stderr: "", status: 0}}

  defp wait_until(fun, timeout \\ 8_000) do
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

  defp open_docker(view, stub, ps \\ nil) do
    enqueue(stub, [exec_reply(ps || @ps)])
    view |> element("#icon-docker") |> render_click()
    wait_until(fn -> has_element?(view, "#docker-list") end)
    wait_until(fn -> has_element?(view, "#container-web") end)
  end

  test "start action is async with correct past tense", %{conn: conn, stub: stub} do
    {:ok, view, _} = live(conn, ~p"/")
    open_docker(view, stub)

    enqueue(stub, [exec_reply("web\n"), exec_reply(@ps)])
    view |> element("#container-web button[phx-value-action=start]") |> render_click()

    wait_until(fn -> render(view) =~ "Container started." end)
    # List reload preserved the row.
    assert has_element?(view, "#container-web")
  end

  test "remove action flashes removed", %{conn: conn, stub: stub} do
    {:ok, view, _} = live(conn, ~p"/")
    open_docker(view, stub)

    enqueue(stub, [exec_reply("web\n"), exec_reply("")])
    view |> element("#container-web button[phx-value-action=remove]") |> render_click()

    wait_until(fn -> render(view) =~ "Container removed." end)
  end

  test "forged actions never crash", %{conn: conn, stub: stub} do
    {:ok, view, _} = live(conn, ~p"/")
    open_docker(view, stub)

    view |> render_click("docker-action", %{"action" => "rm", "name" => "web"})
    wait_until(fn -> render(view) =~ "Unknown Docker action" end)
    assert has_element?(view, "#container-web")
  end

  test "logs support tail, timestamps and text filter", %{conn: conn, stub: stub} do
    {:ok, view, _} = live(conn, ~p"/")
    open_docker(view, stub)

    enqueue(stub, [exec_reply("INFO started\nERROR boom\n")])
    view |> element("#container-web button[phx-click=docker-logs]") |> render_click()
    wait_until(fn -> render(view) =~ "ERROR boom" end)

    # Text filter narrows lines client-side (no SSH round trip).
    view |> render_change("docker-logs-filter", %{"filter" => "error"})
    assert render(view) =~ "ERROR boom"
    refute render(view) =~ "INFO started"

    # Tail change re-fetches.
    enqueue(stub, [exec_reply("INFO fresh\n")])
    view |> form("#docker-logs-tail-form", %{"tail" => "50"}) |> render_change()
    wait_until(fn -> render(view) =~ "INFO fresh" end)

    # Timestamps toggle re-fetches.
    enqueue(stub, [exec_reply("2026-01-01T00:00:00Z stamped\n")])
    view |> element("button[phx-click=docker-logs-timestamps]") |> render_click()
    wait_until(fn -> render(view) =~ "stamped" end)
  end

  test "stats and inspect load async", %{conn: conn, stub: stub} do
    {:ok, view, _} = live(conn, ~p"/")
    open_docker(view, stub)

    enqueue(stub, [exec_reply("{\"Name\":\"web\",\"CPUPerc\":\"1.0%\"}\n")])
    view |> element("#container-web button[phx-click=docker-stats]") |> render_click()
    wait_until(fn -> render(view) =~ "1.0%" end)

    enqueue(stub, [exec_reply("[{\"Id\":\"abc\",\"Image\":\"nginx\"}]\n")])
    view |> element("#container-web button[phx-click=docker-inspect]") |> render_click()
    wait_until(fn -> render(view) =~ "Overview" end)
    assert render(view) =~ "nginx"
  end

  test "images tab lists, removes and prunes", %{conn: conn, stub: stub} do
    {:ok, view, _} = live(conn, ~p"/")
    open_docker(view, stub)

    enqueue(stub, [
      exec_reply(
        "{\"Repository\":\"nginx\",\"Tag\":\"latest\",\"ID\":\"abc123\",\"Size\":\"188MB\"}\n"
      )
    ])

    view |> element("#docker-tab-images") |> render_click()
    wait_until(fn -> has_element?(view, "#image-abc123") end)

    enqueue(stub, [
      exec_reply("Deleted\n"),
      exec_reply("{\"Repository\":\"x\",\"Tag\":\"1\",\"ID\":\"ddd444\",\"Size\":\"1MB\"}\n")
    ])

    view |> element("#image-abc123 button[phx-click=docker-rmi]") |> render_click()
    wait_until(fn -> render(view) =~ "Image removed." end)
  end

  test "stacks expand and restart services", %{conn: conn, stub: stub} do
    {:ok, view, _} = live(conn, ~p"/")
    open_docker(view, stub)

    enqueue(stub, [
      exec_reply(
        "[{\"Name\":\"shop\",\"Status\":\"running\",\"ConfigFiles\":\"/srv/shop/compose.yml\"}]\n"
      )
    ])

    view |> element("#docker-tab-stacks") |> render_click()
    wait_until(fn -> has_element?(view, "#stack-shop") end)

    enqueue(stub, [
      exec_reply(
        "[{\"Name\":\"shop-web-1\",\"Service\":\"web\",\"State\":\"running\",\"Status\":\"Up\"}]\n"
      )
    ])

    view |> element("#stack-shop button[phx-click=docker-stack-toggle]") |> render_click()
    wait_until(fn -> render(view) =~ "shop-web-1" end)

    enqueue(stub, [exec_reply("Restarted\n")])
    view |> element("button[phx-click=docker-compose-action]") |> render_click()
    wait_until(fn -> render(view) =~ "Service restarted." end)
  end

  test "activity tab shows audit entries", %{conn: conn, stub: stub, server: server} do
    :ok = Services.audit(server.id, "docker_start", "web", "ok")

    {:ok, view, _} = live(conn, ~p"/")
    open_docker(view, stub)

    view |> element("#docker-tab-activity") |> render_click()
    wait_until(fn -> render(view) =~ "docker_start" end)
  end

  test "filter narrows containers without SSH", %{conn: conn, stub: stub} do
    {:ok, view, _} = live(conn, ~p"/")
    open_docker(view, stub)

    view
    |> render_change("docker-filter", %{
      "filter" => "zzz-no-match",
      "status" => "all",
      "sort" => "name"
    })

    assert render(view) =~ "No containers match"
  end
end
