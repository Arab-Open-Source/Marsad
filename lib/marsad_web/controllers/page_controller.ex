defmodule MarsadWeb.PageController do
  use MarsadWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
