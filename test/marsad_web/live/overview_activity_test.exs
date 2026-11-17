defmodule MarsadWeb.OverviewActivityTest do
  use MarsadWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Marsad.Fleet
  alias Marsad.Fleet.Services

  setup %{conn: conn} do
    {:ok, server} =
      Fleet.create_server(%{
        name: "overview-host",
        host: "10.0.0.5",
        port: 22,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    :ok = Services.audit(server.id, "docker_start", "web", "ok")
    :ok = Services.audit(server.id, "systemd_restart", "nginx.service", "failed: timeout")

    {:ok, conn: log_in_admin(conn), server: server}
  end

  test "authenticated root is the fleet overview", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#overview-page")
    assert has_element?(view, "#overview-open-desktop")
  end

  test "overview lists servers and recent activity", %{conn: conn, server: server} do
    {:ok, view, _html} = live(conn, ~p"/overview")

    assert has_element?(view, "#overview-page")
    assert has_element?(view, "#overview-server-#{server.id}")
    assert has_element?(view, "#overview-activity")
    assert has_element?(view, "#overview-all-activity")
    assert render(view) =~ "overview-host"
  end

  test "activity timeline lists and filters audit entries", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/activity")

    assert has_element?(view, "#activity-page")
    assert has_element?(view, "#activity-filters")
    assert has_element?(view, "#activity-list")
    assert render(view) =~ "docker_start"
    assert render(view) =~ "systemd_restart"

    view
    |> element("#activity-filters")
    |> render_change(%{
      "filters" => %{"search" => "docker_start", "server_id" => "", "result" => "all"}
    })

    html = render(view)
    assert html =~ "docker_start"
    refute html =~ "systemd_restart"
  end

  test "deep link from overview opens the terminal for a server", %{conn: conn, server: server} do
    {:ok, view, _html} = live(conn, ~p"/desktop?open=terminal&server=#{server.id}")

    assert has_element?(view, "#panel-terminal-#{server.id}")
  end
end
