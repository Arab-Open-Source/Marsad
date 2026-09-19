defmodule MarsadWeb.DesktopPasswordTest do
  use MarsadWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {:ok, conn: log_in_admin(conn)}
  end

  test "change-password rejects mismatch", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#icon-settings") |> render_click()

    view
    |> form("#password-form", %{"password" => "newpassword1", "confirm" => "different2"})
    |> render_submit()

    assert has_element?(view, "#password-msg")
    assert render(view) =~ "do not match"
  end

  test "change-password accepts valid password and signs in with it", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#icon-settings") |> render_click()

    admin_username =
      Marsad.Accounts.first_admin().username

    view
    |> form("#password-form", %{"password" => "brandnewpass1", "confirm" => "brandnewpass1"})
    |> render_submit()

    assert render(view) =~ "Password updated"
    assert {:ok, _} = Marsad.Accounts.authenticate(admin_username, "brandnewpass1")
  end

  test "change-password rejects short password", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#icon-settings") |> render_click()

    view
    |> form("#password-form", %{"password" => "short", "confirm" => "short"})
    |> render_submit()

    assert render(view) =~ "Password updated" == false
  end

  test "reset-auth deletes admin and navigates to setup", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    view |> element("#icon-settings") |> render_click()

    assert Marsad.Accounts.admin_exists?()
    view |> element("#auth-reset") |> render_click()
    assert Marsad.Accounts.admin_exists?() == false
    assert_redirect(view, "/setup")
  end

  test "settings shows current admin and logout link", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/")
    assert has_element?(view, "#topbar-logout")
    view |> element("#icon-settings") |> render_click()
    assert has_element?(view, "#logout-link")
  end
end
