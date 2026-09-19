defmodule MarsadWeb.LiveAuthTest do
  use MarsadWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "guest hitting /login while authenticated is sent home", %{conn: conn} do
    conn = log_in_admin(conn)
    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/login")
  end

  test "authenticated user can open offline page", %{conn: conn} do
    conn = log_in_admin(conn)
    {:ok, view, _} = live(conn, ~p"/offline")
    assert has_element?(view, "#offline-page")
    view |> element("#offline-retry") |> render_click()
    assert has_element?(view, "#offline-page")
  end

  test "unauthenticated user can open offline page (public)", %{conn: _} do
    conn = Phoenix.ConnTest.build_conn()
    {:ok, view, _} = live(conn, ~p"/offline")
    assert has_element?(view, "#offline-page")
  end
end

defmodule MarsadWeb.AuthHTMLTest do
  use MarsadWeb.ConnCase, async: false

  test "setup and login templates render expected copy", %{conn: conn} do
    setup_html = get(conn, ~p"/setup") |> html_response(200)
    assert setup_html =~ "Create admin"

    {:ok, _} =
      Marsad.Accounts.register_admin(%{"username" => "root", "password" => "password1234"})

    login_html = get(conn, ~p"/login") |> html_response(200)
    assert login_html =~ "Sign in"
  end

  test "authenticated GET /login redirects home", %{conn: conn} do
    conn = conn |> log_in_admin() |> get(~p"/login")
    assert redirected_to(conn) == "/"
  end
end

defmodule MarsadWeb.FileDownloadControllerTest do
  use MarsadWeb.ConnCase, async: false

  test "rejects missing params with 400", %{conn: conn} do
    conn = conn |> log_in_admin() |> get(~p"/files/download")
    assert text_response(conn, 400) =~ "Missing"
  end

  test "rejects unknown server with 400", %{conn: conn} do
    conn = conn |> log_in_admin() |> get(~p"/files/download?server_id=999999&path=/x")
    assert text_response(conn, 400) =~ "Missing or invalid"
  end

  test "unreachable server yields 404, not 500", %{conn: conn} do
    {:ok, server} =
      Marsad.Fleet.create_server(%{
        name: "dl-#{System.unique_integer([:positive])}",
        host: "127.0.0.1",
        port: 1,
        username: "root",
        auth_type: "password",
        secret: "x"
      })

    conn =
      conn
      |> log_in_admin()
      |> get(~p"/files/download?server_id=#{server.id}&path=/etc/hosts")

    assert text_response(conn, 404) =~ "Download failed"
  end
end
