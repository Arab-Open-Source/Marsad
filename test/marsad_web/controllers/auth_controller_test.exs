defmodule MarsadWeb.AuthControllerTest do
  use MarsadWeb.ConnCase, async: false

  test "setup creates admin and signs in", %{conn: conn} do
    conn =
      post(conn, ~p"/setup", %{"admin" => %{"username" => "boss", "password" => "password1234"}})

    assert redirected_to(conn) == "/"
    assert get_session(conn, :admin_id)
  end

  test "setup redirects to login when already set up", %{conn: conn} do
    {:ok, _} =
      Marsad.Accounts.register_admin(%{"username" => "one", "password" => "password1234"})

    conn = get(conn, ~p"/setup")
    assert redirected_to(conn) == "/login"
  end

  test "login rejects bad credentials, accepts good ones", %{conn: conn} do
    {:ok, _} =
      Marsad.Accounts.register_admin(%{"username" => "sam", "password" => "password1234"})

    bad =
      post(conn, ~p"/login", %{"admin" => %{"username" => "sam", "password" => "nope-nope-nope"}})

    assert html_response(bad, 422) =~ "Invalid username"

    good =
      post(conn, ~p"/login", %{"admin" => %{"username" => "sam", "password" => "password1234"}})

    assert redirected_to(good) == "/"
    assert get_session(good, :admin_id)
  end

  test "login accepts flat (unscoped) params", %{conn: conn} do
    {:ok, _} =
      Marsad.Accounts.register_admin(%{"username" => "flat", "password" => "password1234"})

    conn = post(conn, ~p"/login", %{"username" => "flat", "password" => "password1234"})
    assert redirected_to(conn) == "/"
    assert get_session(conn, :admin_id)
  end

  test "login with missing params renders error instead of crashing", %{conn: conn} do
    {:ok, _} =
      Marsad.Accounts.register_admin(%{"username" => "sam", "password" => "password1234"})

    assert html_response(post(conn, ~p"/login", %{}), 422) =~ "Invalid username"
    assert html_response(post(conn, ~p"/login", %{"admin" => %{}}), 422) =~ "Invalid username"

    assert html_response(post(conn, ~p"/login", %{"admin" => "garbage"}), 422) =~
             "Invalid username"
  end

  test "setup accepts flat (unscoped) params", %{conn: conn} do
    conn = post(conn, ~p"/setup", %{"username" => "flatboss", "password" => "password1234"})
    assert redirected_to(conn) == "/"
    assert get_session(conn, :admin_id)
  end

  test "logout drops session", %{conn: conn} do
    conn = conn |> log_in_admin() |> get(~p"/logout")
    assert redirected_to(conn) == "/login"
    # Session cookie is dropped; a fresh request is unauthenticated.
    fresh = Phoenix.ConnTest.build_conn() |> get(~p"/")
    assert redirected_to(fresh) == "/login"
  end

  test "download requires auth", %{conn: conn} do
    {:ok, _} =
      Marsad.Accounts.register_admin(%{"username" => "root", "password" => "password1234"})

    conn = get(conn, ~p"/files/download?server_id=1&path=/x")
    assert redirected_to(conn) == "/login"
  end

  test "download redirects fresh installs to setup", %{conn: conn} do
    conn = get(conn, ~p"/files/download?server_id=1&path=/x")
    assert redirected_to(conn) == "/setup"
  end
end
