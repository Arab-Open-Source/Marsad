defmodule MarsadWeb.DesktopLiveTest do
  use MarsadWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "desktop shell renders with app icons and taskbar", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#desktop-shell")
    assert has_element?(view, "#desktop-icons")
    assert has_element?(view, "#desktop-taskbar")
    assert has_element?(view, "#icon-terminal")
    assert has_element?(view, "#icon-servers")
  end

  test "opening the terminal app spawns a tab with an xterm hook", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#cta-open-servers") |> render_click()
    assert has_element?(view, "#tab-servers")
    assert has_element?(view, "#panel-servers")

    view |> element("#icon-terminal") |> render_click()
    assert has_element?(view, "#tab-terminal")
    assert has_element?(view, "#terminal-terminal")
  end

  test "settings app switches theme and accent, persisted in DB", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#icon-settings") |> render_click()
    assert has_element?(view, "#settings-appearance")

    view |> element("#theme-light") |> render_click()
    assert Marsad.Settings.appearance().mode == "light"

    view |> element("#accent-rose") |> render_click()
    assert Marsad.Settings.appearance().accent == "rose"

    # Invalid values are ignored
    view |> render_click("set-accent", %{"accent" => "hotpink"})
    assert Marsad.Settings.appearance().accent == "rose"
  end

  test "tabs switch without losing panels, and close works", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#icon-servers") |> render_click()
    view |> element("#icon-terminal") |> render_click()
    assert has_element?(view, "#tab-servers")
    assert has_element?(view, "#tab-terminal")
    # Both panels stay mounted (state preserved), only one visible
    assert has_element?(view, "#panel-servers")
    assert has_element?(view, "#panel-terminal")

    # Switch back to servers tab
    view |> element("#switchtab-servers") |> render_click()
    html = render(view)
    assert html =~ "panel-servers"
    assert html =~ "panel-terminal"

    # Close the terminal tab
    view |> element("#closetab-terminal") |> render_click()
    refute has_element?(view, "#tab-terminal")
    assert has_element?(view, "#tab-servers")
  end

  test "files tab shows skeleton then error for unreachable server", %{conn: conn} do
    {:ok, server} =
      Marsad.Fleet.create_server(%{
        name: "down",
        host: "127.0.0.1",
        port: 22,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    assert server.id
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#icon-files") |> render_click()
    assert has_element?(view, "#files-skeleton")

    wait_until(fn -> has_element?(view, "#files-error") end)
    assert has_element?(view, "#files-error")
  end

  defp wait_until(fun, timeout \\ 8000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("async condition was not met in time")

      true ->
        Process.sleep(50)
        do_wait(fun, deadline)
    end
  end

  test "files and monitor tabs render empty states without servers", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#icon-files") |> render_click()
    assert has_element?(view, "#files-browser")
    assert has_element?(view, "#files-empty")

    view |> element("#icon-monitor") |> render_click()
    assert has_element?(view, "#monitor-panel")
    assert has_element?(view, "#monitor-empty")
  end

  test "docker, systemd and nginx tabs render empty states without servers", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#icon-docker") |> render_click()
    assert has_element?(view, "#docker-panel")
    assert has_element?(view, "#docker-empty")

    view |> element("#icon-systemd") |> render_click()
    assert has_element?(view, "#systemd-panel")
    assert has_element?(view, "#systemd-empty")

    view |> element("#icon-nginx") |> render_click()
    assert has_element?(view, "#nginx-panel")
    assert has_element?(view, "#nginx-empty")
  end

  test "servers app can add a server", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    view |> element("#cta-open-servers") |> render_click()
    view |> element("#new-server") |> render_click()
    assert has_element?(view, "#server-form")

    view
    |> form("#server-form",
      server: %{
        name: "t1",
        host: "127.0.0.1",
        port: 22,
        username: "root",
        auth_type: "password",
        secret: "x"
      }
    )
    |> render_submit()

    assert has_element?(view, "#servers-list")
    html = render(view)
    assert html =~ "t1"
  end
end
