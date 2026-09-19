defmodule MarsadWeb.RootRoutesTest do
  use MarsadWeb.ConnCase, async: false

  test "GET / redirects to setup on fresh install", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/setup"
  end

  test "GET / redirects to login for guests once admin exists", %{conn: conn} do
    {:ok, _} =
      Marsad.Accounts.register_admin(%{"username" => "root", "password" => "password1234"})

    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/login"
  end

  test "GET / renders desktop when authenticated", %{conn: conn} do
    conn = conn |> log_in_admin() |> get(~p"/")
    html = html_response(conn, 200)
    assert html =~ "Marsad"
  end

  test "GET /offline is public", %{conn: conn} do
    conn = get(conn, ~p"/offline")
    assert html_response(conn, 200) =~ "offline"
  end

  test "GET /login redirects to setup before first admin", %{conn: conn} do
    conn = get(conn, ~p"/login")
    assert redirected_to(conn) == "/setup"
  end

  test "GET /login renders and /setup redirects once set up", %{conn: conn} do
    {:ok, _} =
      Marsad.Accounts.register_admin(%{"username" => "root", "password" => "password1234"})

    assert html_response(get(conn, ~p"/login"), 200) =~ "Sign in"
    assert redirected_to(get(conn, ~p"/setup")) == "/login"
  end

  test "GET /setup renders the registration form", %{conn: conn} do
    assert html_response(get(conn, ~p"/setup"), 200) =~ "Create admin"
  end
end
