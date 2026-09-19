defmodule MarsadWeb.TerminalTest do
  use MarsadWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Marsad.Fleet
  alias Marsad.SSH.FakeShellTransport

  setup %{conn: conn} do
    start_supervised!(FakeShellTransport)
    FakeShellTransport.reset()

    {:ok, server} =
      Fleet.create_server(%{
        name: "term-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 22,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    on_exit(fn -> Marsad.Fleet.ServerShell.close_for_server(server.id) end)

    {:ok, conn: log_in_admin(conn), server: server}
  end

  defp drain_connecting(view) do
    assert_push_event(view, "terminal_output", %{data: data}, 2000)
    assert data =~ "connecting to"
  end

  defp open_terminal(view) do
    view |> element("#icon-terminal") |> render_click()
  end

  defp ready(view, wid, cols \\ 80, rows \\ 24) do
    view |> render_click("terminal_ready", %{"window_id" => wid, "cols" => cols, "rows" => rows})
  end

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

  test "server window negotiates shell mode and streams raw bytes", %{conn: conn, server: server} do
    {:ok, view, _} = live(conn, ~p"/")
    open_terminal(view)
    wid = "terminal-#{server.id}"

    ready(view, wid)
    assert_push_event(view, "terminal_mode", %{mode: "shell"}, 1000)
    drain_connecting(view)

    FakeShellTransport.enqueue("hi\r\nhost$ ")
    view |> render_click("terminal_input", %{"data" => "echo hi\r", "window_id" => wid})
    assert_push_event(view, "terminal_output", %{data: data}, 2000)
    assert data =~ "hi"

    # Raw bytes (with \r) reached the transport untouched.
    assert {:send, "echo hi\r"} in FakeShellTransport.sent()
  end

  test "fullscreen escape sequences flow through (vim/nano/top)", %{conn: conn, server: server} do
    {:ok, view, _} = live(conn, ~p"/")
    open_terminal(view)
    wid = "terminal-#{server.id}"
    ready(view, wid)
    assert_push_event(view, "terminal_mode", %{mode: "shell"}, 1000)
    drain_connecting(view)

    FakeShellTransport.enqueue("\e[?1049h\e[22;0;0t")
    view |> render_click("terminal_input", %{"data" => "vim notes\r", "window_id" => wid})
    assert_push_event(view, "terminal_output", %{data: data}, 2000)
    assert data =~ "\e[?1049h"
  end

  test "cd and later commands stream in order", %{conn: conn, server: server} do
    {:ok, view, _} = live(conn, ~p"/")
    open_terminal(view)
    wid = "terminal-#{server.id}"
    ready(view, wid)
    assert_push_event(view, "terminal_mode", %{mode: "shell"}, 1000)
    drain_connecting(view)

    FakeShellTransport.enqueue("host:/tmp$ ")
    view |> render_click("terminal_input", %{"data" => "cd /tmp\r", "window_id" => wid})
    assert_push_event(view, "terminal_output", %{data: first}, 2000)
    assert first =~ "/tmp"

    FakeShellTransport.enqueue("/tmp\r\nhost:/tmp$ ")
    view |> render_click("terminal_input", %{"data" => "pwd\r", "window_id" => wid})
    assert_push_event(view, "terminal_output", %{data: second}, 2000)
    assert second =~ "/tmp"

    sends = for {:send, bin} <- FakeShellTransport.sent(), do: bin
    assert sends == ["cd /tmp\r", "pwd\r"]
  end

  test "exit ends the session; next input reopens it", %{conn: conn, server: server} do
    {:ok, view, _} = live(conn, ~p"/")
    open_terminal(view)
    wid = "terminal-#{server.id}"
    ready(view, wid)
    assert_push_event(view, "terminal_mode", %{mode: "shell"}, 1000)
    drain_connecting(view)

    FakeShellTransport.enqueue(:closed)
    view |> render_click("terminal_input", %{"data" => "exit\r", "window_id" => wid})
    assert_push_event(view, "terminal_output", %{data: ended}, 2000)
    assert ended =~ "session ended"

    FakeShellTransport.enqueue("fresh$ ")
    view |> render_click("terminal_input", %{"data" => "echo again\r", "window_id" => wid})
    assert_push_event(view, "terminal_output", %{data: reopened}, 2000)
    assert reopened =~ "fresh"
  end

  test "failed shell open shows an error, retry works", %{conn: conn, server: server} do
    {:ok, view, _} = live(conn, ~p"/")
    open_terminal(view)
    wid = "terminal-#{server.id}"

    FakeShellTransport.fail_open_once(:econnrefused)
    ready(view, wid)
    assert_push_event(view, "terminal_mode", %{mode: "shell"}, 1000)
    drain_connecting(view)
    # The failed open itself reports an error; drain it before retrying.
    assert_push_event(view, "terminal_output", %{data: failed}, 2000)
    assert failed =~ "cannot open shell"

    FakeShellTransport.enqueue("ok$ ")
    view |> render_click("terminal_input", %{"data" => "echo retry\r", "window_id" => wid})
    assert_push_event(view, "terminal_output", %{data: data}, 2000)
    assert data =~ "ok"
  end

  test "resize is forwarded with real dimensions", %{conn: conn, server: server} do
    {:ok, view, _} = live(conn, ~p"/")
    open_terminal(view)
    wid = "terminal-#{server.id}"
    ready(view, wid, 100, 30)
    assert_push_event(view, "terminal_mode", %{mode: "shell"}, 1000)
    drain_connecting(view)

    assert {:open_shell, 100, 30} in FakeShellTransport.sent()

    view
    |> render_click("terminal_resize", %{"cols" => 120, "rows" => 40, "window_id" => wid})

    assert {:resize, 120, 40} in FakeShellTransport.sent()
  end

  test "peer pill shows connecting, then a plain SSH chip once open", %{
    conn: conn,
    server: server
  } do
    {:ok, view, _} = live(conn, ~p"/")
    open_terminal(view)
    wid = "terminal-#{server.id}"

    FakeShellTransport.gate_open()
    ready(view, wid)
    assert_push_event(view, "terminal_mode", %{mode: "shell"}, 1000)

    html = render(view)
    assert html =~ "connecting…"
    refute html =~ "running…"

    FakeShellTransport.release_open()
    wait_until(fn -> render(view) =~ "SSH · 127.0.0.1:22" end)
    html = render(view)
    assert html =~ "SSH · 127.0.0.1:22"
    refute html =~ "running…"
    refute html =~ "connecting…"
  end

  test "toolbar clear wipes the screen", %{conn: conn, server: server} do
    {:ok, view, _} = live(conn, ~p"/")
    open_terminal(view)
    wid = "terminal-#{server.id}"
    ready(view, wid)
    assert_push_event(view, "terminal_mode", %{mode: "shell"}, 1000)
    drain_connecting(view)

    view |> element("#termclear-#{wid}") |> render_click()
    assert_push_event(view, "terminal_clear", %{window_id: ^wid}, 1000)
  end

  test "demo mode echoes without a server", %{conn: conn} do
    for s <- Fleet.list_servers(), do: {:ok, _} = Fleet.delete_server(s)

    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#icon-terminal") |> render_click()

    view |> render_click("terminal_ready", %{"window_id" => "terminal"})
    assert_push_event(view, "terminal_mode", %{mode: "demo"}, 1000)
    assert_push_event(view, "terminal_output", %{data: banner}, 1000)
    assert banner =~ "demo mode"

    view |> render_click("terminal_input", %{"data" => "echo hi\n", "window_id" => "terminal"})
    assert_push_event(view, "terminal_output", %{data: data}, 1000)
    assert data =~ "hi"

    view |> render_click("terminal_input", %{"data" => "whatever\n", "window_id" => "terminal"})
    assert_push_event(view, "terminal_output", %{data: demo}, 1000)
    assert demo =~ "demo mode"
  end
end
