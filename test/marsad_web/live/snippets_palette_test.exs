defmodule MarsadWeb.SnippetsPaletteTest do
  use MarsadWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Marsad.Fleet
  alias Marsad.Snippets
  alias MarsadWeb.FileSessionStub

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

  defp start_stub(server_id, attempts \\ 5) do
    case Registry.lookup(Marsad.Fleet.Registry, server_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Marsad.Fleet.DynamicSupervisor, pid)
      [] -> :ok
    end

    case FileSessionStub.start_link(server_id: server_id, owner: self()) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, _}} when attempts > 1 ->
        Process.sleep(50)
        start_stub(server_id, attempts - 1)

      {:error, reason} ->
        flunk("could not start stub: #{inspect(reason)}")
    end
  end

  setup %{conn: conn} do
    {:ok, server} =
      Fleet.create_server(%{
        name: "runbook-host",
        host: "10.0.0.9",
        port: 22,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    {:ok, conn: log_in_admin(conn), server: server}
  end

  test "snippets page creates, selects and deletes a runbook", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/snippets")
    assert has_element?(view, "#snippets-page")

    view |> element("#snippet-new") |> render_click()
    assert has_element?(view, "#snippet-form")

    view
    |> element("#snippet-form")
    |> render_submit(%{
      "snippet" => %{
        "name" => "Check disk",
        "description" => "df on a path",
        "category" => "storage",
        "command" => "df -h {{path}}",
        "variables" => ""
      }
    })

    snippet = Snippets.list_snippets() |> hd()
    assert snippet.name == "Check disk"
    assert snippet.variables == ~s(["path"])
    assert has_element?(view, "#snippet-#{snippet.id}")
    assert has_element?(view, "#snippet-run-panel")

    view |> element("#snippet-delete-#{snippet.id}") |> render_click()
    refute has_element?(view, "#snippet-#{snippet.id}")
  end

  test "runbook renders variables and executes on a selected server", %{
    conn: conn,
    server: server
  } do
    stub = start_stub(server.id)
    on_exit(fn -> if Process.alive?(stub), do: GenServer.stop(stub) end)

    {:ok, snippet} =
      Snippets.create_snippet(%{
        "name" => "Echo word",
        "description" => "echo test",
        "command" => "echo {{word}}",
        "category" => "general"
      })

    {:ok, view, _html} = live(conn, ~p"/snippets?run=#{snippet.id}")
    assert has_element?(view, "#snippet-run-panel")

    view
    |> element("#snippet-run-form")
    |> render_change(%{"word" => "hello", "servers[#{server.id}]" => "true"})

    FileSessionStub.enqueue(stub, {:ok, %{stdout: "hello\n", stderr: "", status: 0}})

    view
    |> element("#snippet-run-form")
    |> render_submit(%{"word" => "hello", "servers[#{server.id}]" => "true"})

    wait_until(fn -> render(view) =~ "hello" end)
    assert has_element?(view, "#snippet-results")
  end

  test "command palette opens, searches and navigates", %{conn: conn, server: server} do
    {:ok, view, _html} = live(conn, ~p"/desktop")

    refute has_element?(view, "#command-palette")
    view |> element("#nav-palette") |> render_click()
    assert has_element?(view, "#command-palette")
    assert has_element?(view, "#command-palette-input")

    view
    |> element("#command-palette-input")
    |> render_change(%{"query" => "overview"})

    assert has_element?(view, "#palette-item-page--overview")

    {:error, {:live_redirect, %{to: to}}} =
      view |> element("#palette-item-page--overview") |> render_click()

    assert to == "/overview"

    # Server shortcut opens a terminal without navigating.
    {:ok, view, _html} = live(conn, ~p"/desktop")
    view |> element("#nav-palette") |> render_click()
    assert has_element?(view, "#palette-item-server-#{server.id}")

    view |> element("#palette-item-server-#{server.id}") |> render_click()
    assert has_element?(view, "#panel-terminal-#{server.id}")
  end

  test "command palette can launch a runbook", %{conn: conn} do
    {:ok, snippet} =
      Snippets.create_snippet(%{
        "name" => "Uptime",
        "description" => "show uptime",
        "command" => "uptime",
        "category" => "general"
      })

    {:ok, view, _html} = live(conn, ~p"/desktop")
    view |> element("#nav-palette") |> render_click()
    assert has_element?(view, "#palette-item-snippet-#{snippet.id}")

    {:error, {:live_redirect, %{to: to}}} =
      view |> element("#palette-item-snippet-#{snippet.id}") |> render_click()

    assert to == "/snippets?run=#{snippet.id}"
  end
end
