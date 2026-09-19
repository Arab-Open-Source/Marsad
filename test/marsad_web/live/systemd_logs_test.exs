defmodule MarsadWeb.SystemdLogsTest do
  use MarsadWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Marsad.Fleet
  alias MarsadWeb.FileSessionStub

  setup %{conn: conn} do
    {:ok, server} =
      Fleet.create_server(%{
        name: "journal-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 22,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    kill_registry(server.id)
    stub = start_stub(server.id)
    on_exit(fn -> if Process.alive?(stub), do: GenServer.stop(stub, :normal, 1000) end)

    {:ok, conn: log_in_admin(conn), stub: stub}
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

  test "journal opens with count, collapses and wraps", %{conn: conn, stub: stub} do
    {:ok, view, _} = live(conn, ~p"/")

    enqueue(stub, [exec_reply("cron.service loaded active running Cron daemon\n")])
    view |> element("#icon-systemd") |> render_click()
    wait_until(fn -> has_element?(view, "#systemd-list") end)

    enqueue(stub, [exec_reply("Jan 01 boot\nJan 01 tick\n")])
    view |> element("button[phx-click=systemd-logs]") |> render_click()
    wait_until(fn -> render(view) =~ "2 lines" end)
    assert render(view) =~ "Jan 01 boot"

    view |> element("#systemd-logs-collapse") |> render_click()
    assert render(view) =~ "2 lines hidden"

    view |> element("#systemd-logs-collapse") |> render_click()
    view |> element("button[phx-click=systemd-logs-wrap]") |> render_click()
    assert render(view) =~ "whitespace-pre-wrap"
  end
end
