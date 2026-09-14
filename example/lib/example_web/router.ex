defmodule ExampleWeb.Router do
  use ExampleWeb, :router

  # `quick_view/3` comes from here. The macro writes each view's base path into
  # the route metadata, which is where the view reads it back at request time —
  # so a path is stated once and cannot drift from its module.
  import AshQuick.LiveView.Router
  import ExampleWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ExampleWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_user
    plug :assign_scope
  end

  pipeline :user_required do
    plug :require_user
  end

  scope "/", ExampleWeb do
    pipe_through :browser

    # No token can resolve without a session, but AshQuick's mount stage is
    # still here for the address it reads: `:assign_scope` builds the same scope
    # on both sides of the sign-in page.
    live_session :no_user,
      layout: {ExampleWeb.Layouts, :app},
      on_mount: [
        AshQuick.LiveView.Mount,
        {ExampleWeb.UserAuth, :assign_scope},
        {ExampleWeb.UserAuth, :require_no_user}
      ] do
      live "/login", LoginLive, :index
    end

    post "/session", SessionController, :create
    get "/sign-out", SessionController, :delete
  end

  scope "/", ExampleWeb do
    pipe_through [:browser, :user_required]

    # AshQuick's mount goes first: it resolves the tab's impersonation and reads
    # the connection's address, and `:assign_scope` is what consumes both.
    live_session :authenticated,
      layout: {ExampleWeb.Layouts, :app},
      on_mount: [
        AshQuick.LiveView.Mount,
        {ExampleWeb.UserAuth, :assign_scope},
        {ExampleWeb.UserAuth, :require_user}
      ] do
      live "/", HomeLive, :index

      quick_view "/brands", BrandLive.Quick
      quick_view "/categories", CategoryLive.Quick
      quick_view "/products", ProductLive.Quick

      # Written only by `Product.reprice`, so there is no create form to offer.
      quick_view "/price_changes", PriceChangeLive.Quick, except: [:create]

      quick_view "/users", UserLive.Quick

      # Append-only, and read-only to a person.
      quick_view "/audit_logs", AuditLogLive.Quick, only: [:index, :show]
      quick_view "/file_objects", FileObjectLive.Quick, only: [:index, :show]

      # The library's own page over `AshQuick.BrowserSessionPresence`. It
      # belongs to AshQuick, so it needs its own scope — the enclosing one
      # prefixes `ExampleWeb.` onto every module it is handed.
      scope "/", alias: false do
        live "/browser_sessions", AshQuick.LiveView.BrowserSessionsLive, :index
      end
    end
  end

  if Application.compile_env(:example, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ExampleWeb.Telemetry
    end
  end
end
