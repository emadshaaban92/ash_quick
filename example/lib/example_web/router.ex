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
        {ExampleWeb.UserAuth, :assign_current_user},
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
        {ExampleWeb.UserAuth, :assign_current_user},
        AshQuick.LiveView.Mount,
        {ExampleWeb.UserAuth, :assign_scope},
        {ExampleWeb.UserAuth, :require_user}
      ] do
      live "/", HomeLive, :index

      quick_view "/stores", StoreLive.Quick
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

  # Pages over resources that exist only in the test build (`test/support`),
  # for the cases no resource in this application can show. Behind the same
  # session and sign-in as every other page, but no role is granted them: the
  # access gate would refuse each one, so they skip it — and nobody's nav or
  # grid offers them.
  if Application.compile_env(:example, :test_routes) do
    scope "/test", alias: false do
      pipe_through [:browser, :user_required]

      live_session :test_only,
        layout: {ExampleWeb.Layouts, :app},
        on_mount: [
          {ExampleWeb.UserAuth, :assign_current_user},
          AshQuick.LiveView.Mount,
          {ExampleWeb.UserAuth, :assign_scope}
        ] do
        quick_view "/bulk_guarded", Example.Test.BulkGuardedLive.Quick
        quick_view "/bulk_named", Example.Test.BulkNamedLive.Quick
        quick_view "/dated_entries", Example.Test.DatedEntriesLive.Quick
        quick_view "/default_pages", Example.Test.DefaultPagesLive.Quick
        quick_view "/digits_only", Example.Test.DigitsOnlyLive.Quick
        quick_view "/enum_picks", Example.Test.EnumPicksLive.Quick
        quick_view "/field_rows", Example.Test.FieldRowsLive.Quick
        quick_view "/filter_fields", Example.Test.FilterFieldsLive.Quick
        quick_view "/form_stages", Example.Test.FormStagesLive.Quick
        quick_view "/hidden_address", Example.Test.HiddenAddressLive.Quick
        quick_view "/lookup_items", Example.Test.LookupItemsLive.Quick
        quick_view "/nested_items", Example.Test.NestedItemsLive.Quick
        quick_view "/picked_labels", Example.Test.PickedLabelsLive.Quick
        quick_view "/printable", Example.Test.PrintableLive.Quick
        quick_view "/private_create", Example.Test.PrivateCreateLive.Quick
        quick_view "/required_attachments", Example.Test.RequiredAttachmentsLive.Quick
        quick_view "/required_entries", Example.Test.RequiredEntriesLive.Quick
        quick_view "/required_picks", Example.Test.RequiredPicksLive.Quick
        quick_view "/secrets", Example.Test.SecretsLive.Quick
        quick_view "/second_lists", Example.Test.SecondListsLive.Quick
        quick_view "/shadowed_arguments", Example.Test.ShadowedArgumentsLive.Quick
        quick_view "/shelved_crates", Example.Test.ShelvedCratesLive.Quick
        quick_view "/small_pages", Example.Test.SmallPagesLive.Quick
        quick_view "/sorted_rows", Example.Test.SortedRowsLive.Quick
        quick_view "/sorted_rows_named", Example.Test.SortedRowsNamedLive.Quick
        quick_view "/worded_policy", Example.Test.WordedPolicyLive.Quick
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
