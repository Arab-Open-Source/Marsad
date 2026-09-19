defmodule MarsadWeb.SessionController do
  use MarsadWeb, :controller

  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end
end
