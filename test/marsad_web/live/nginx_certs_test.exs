defmodule MarsadWeb.NginxCertsTest do
  use MarsadWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Marsad.Fleet
  alias MarsadWeb.FileSessionStub

  setup %{conn: conn} do
    {:ok, server} =
      Fleet.create_server(%{
        name: "nginx-certs-#{System.unique_integer([:positive])}",
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

  defp openssl_date(dt) do
    months = ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)

    "#{Enum.at(months, dt.month - 1)} #{dt.day} #{pad(dt.hour)}:#{pad(dt.minute)}:#{pad(dt.second)} #{dt.year} GMT"
  end

  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")

  test "check button loads the certificate table", %{conn: conn, stub: stub} do
    {:ok, view, _} = live(conn, ~p"/")

    # nginx open: status is 2 execs (is-active + nginx -t), then files list.
    enqueue(stub, [
      exec_reply("active\n"),
      exec_reply("syntax ok\ntest is successful\n"),
      exec_reply("")
    ])

    view |> element("#icon-nginx") |> render_click()
    wait_until(fn -> has_element?(view, "#nginx-certs-check") end)

    dump = "server {\n listen 443 ssl;\n server_name shop.example.com;\n}\n"
    future = openssl_date(DateTime.add(DateTime.utc_now(), 90 * 86_400, :second))

    enqueue(stub, [
      exec_reply(dump),
      exec_reply("shop.example.com|443|#{future}\n")
    ])

    view |> element("#nginx-certs-check") |> render_click()
    wait_until(fn -> render(view) =~ "shop.example.com" end)
    assert render(view) =~ "all valid"
  end

  test "error log collapses and closes", %{conn: conn, stub: stub} do
    {:ok, view, _} = live(conn, ~p"/")

    enqueue(stub, [
      exec_reply("active\n"),
      exec_reply("syntax ok\ntest is successful\n"),
      exec_reply("")
    ])

    view |> element("#icon-nginx") |> render_click()
    wait_until(fn -> has_element?(view, "#nginx-log-load") end)

    enqueue(stub, [exec_reply("2026/01/01 [error] boom\n2026/01/01 [warn] meh\n")])
    view |> element("#nginx-log-load") |> render_click()
    wait_until(fn -> render(view) =~ "2 lines" end)

    view |> element("#nginx-log-collapse") |> render_click()
    assert render(view) =~ "2 lines hidden"

    view |> element("#nginx-log-close") |> render_click()
    refute has_element?(view, "#nginx-log-close")
  end

  test "renew button opens a live modal ending in success", %{conn: conn, stub: stub} do
    {:ok, view, _} = live(conn, ~p"/")

    enqueue(stub, [
      exec_reply("active\n"),
      exec_reply("syntax ok\ntest is successful\n"),
      exec_reply("")
    ])

    view |> element("#icon-nginx") |> render_click()
    wait_until(fn -> has_element?(view, "#nginx-certs-check") end)

    dump = "server {\n listen 443 ssl;\n server_name shop.example.com;\n}\n"
    future = openssl_date(DateTime.add(DateTime.utc_now(), 90 * 86_400, :second))

    enqueue(stub, [
      exec_reply(dump),
      exec_reply("shop.example.com|443|#{future}\n")
    ])

    view |> element("#nginx-certs-check") |> render_click()
    wait_until(fn -> render(view) =~ "shop.example.com" end)

    enqueue(stub, [
      exec_reply("Certificate Name: shop.example.com\n  Domains: shop.example.com\n"),
      exec_reply("Congratulations! Renewed.\n"),
      exec_reply("syntax ok\n"),
      exec_reply(dump),
      exec_reply("shop.example.com|443|#{future}\n")
    ])

    view
    |> element("button[phx-click=nginx-renew-cert][phx-value-domain=\"shop.example.com\"]")
    |> render_click()

    wait_until(fn -> has_element?(view, "#nginx-renew-modal") end)
    wait_until(fn -> render(view) =~ "Renewed &" end)
    wait_until(fn -> render(view) =~ "verified expiry" end)

    view |> element("#nginx-renew-close-btn") |> render_click()
    refute has_element?(view, "#nginx-renew-modal")
  end

  test "critical certs raise a summary pill", %{conn: conn, stub: stub} do
    {:ok, view, _} = live(conn, ~p"/")

    enqueue(stub, [
      exec_reply("active\n"),
      exec_reply("syntax ok\ntest is successful\n"),
      exec_reply("")
    ])

    view |> element("#icon-nginx") |> render_click()
    wait_until(fn -> has_element?(view, "#nginx-certs-check") end)

    dump = "server {\n listen 443 ssl;\n server_name old.example.com;\n}\n"
    past = openssl_date(DateTime.add(DateTime.utc_now(), -2 * 86_400, :second))

    enqueue(stub, [
      exec_reply(dump),
      exec_reply("old.example.com|443|#{past}\n")
    ])

    view |> element("#nginx-certs-check") |> render_click()
    wait_until(fn -> render(view) =~ "1 critical" end)
    assert render(view) =~ "expired"
  end
end
