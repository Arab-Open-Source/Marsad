defmodule MarsadWeb.Router do
  use MarsadWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {MarsadWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :require_admin do
    plug MarsadWeb.Plugs.RequireAdmin
  end

  # Public: offline diagnostics (no auth on purpose).
  scope "/", MarsadWeb do
    pipe_through :browser

    live_session :public do
      live "/offline", OfflineLive, :index
    end
  end

  # Guest-only: setup + login (plain controllers so session cookies are written reliably).
  scope "/", MarsadWeb do
    pipe_through :browser

    get "/setup", AuthController, :setup
    post "/setup", AuthController, :create_setup
    get "/login", AuthController, :login
    post "/login", AuthController, :create_login

    get "/logout", SessionController, :delete
  end

  # Authenticated app.
  scope "/", MarsadWeb do
    pipe_through [:browser, :require_admin]

    live_session :app, on_mount: {MarsadWeb.LiveAuth, :ensure} do
      live "/", DesktopLive, :index
    end

    get "/files/download", FileDownloadController, :download
  end

  # Other scopes may use custom stacks.
  # scope "/api", MarsadWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:marsad, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: MarsadWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
