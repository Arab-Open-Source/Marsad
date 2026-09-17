defmodule MarsadWeb.PageControllerTest do
  use MarsadWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ "Marsad"
  end
end
