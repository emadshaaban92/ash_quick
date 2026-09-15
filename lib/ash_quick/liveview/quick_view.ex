defmodule AshQuick.LiveView.QuickView do
  @moduledoc """
  The main macro that wires up a full CRUD LiveView from declarative config.

  `use AshQuick.LiveView.QuickView` turns a module into a LiveView with automatic
  list, detail, create, and update views — driven entirely by your Ash resource
  definition and a small set of options.

  ## Minimal example

      defmodule MyAppWeb.ProductLive.Quick do
        use AshQuick.LiveView.QuickView,
          resource: MyApp.Catalog.Product,
          list: [
            fields: [:code, :name, :price, :quantity],
            new_action_label: "Add Product"
          ],
          details: [
            fields: [:code, :name, :description, :price, :quantity, :created_at]
          ]
      end

  ## Router setup

  Routes are declared with `AshQuick.LiveView.Router.quick_view/3`, which
  states the path once and pins it to the routes it generates. The layout
  must be set on the `live_session` (QuickView does not set one):

      import AshQuick.LiveView.Router

      live_session :my_session, layout: {MyAppWeb.Layouts, :app} do
        quick_view "/products", ProductLive.Quick
        # ...
      end

  ## Options

  ### Required

    * `:resource` — The Ash resource module (e.g. `MyApp.Catalog.Product`).

  The URL the view is served at is not an option here — it is declared once in
  the router, with `AshQuick.LiveView.Router.quick_view/3`, and read back from
  the route as the `@base_path` assign.

  ### Optional

    * `:sort_by` — Default sort for list queries (e.g. `[name: :asc]`).
    * `:load` — Extra fields or relationships to load on every query.
    * `:base_filter` — An Ash expression that is always applied to list queries.
    * `:sidebar` — Controls the navigation sidebar. Defaults to `true`.
      Set to `false` to hide the sidebar and use the full page width.
    * `:liveness_options` — Tuning for real-time updates. Whether a view is live
      at all is the resource's call: it is, exactly when the resource carries
      the `AshQuick` extension with liveness enabled, which is what publishes.
      Topics are derived from `AshQuick.Topics`, never named here, so they
      cannot drift from what the resources publish.
      * `:recursive?` — How far the derivation reaches. `true` (the default)
        walks the fetched data and listens to every related record it
        materialized, so the page goes live on the values it renders. `false`
        stops at the records in the assign — the rows on screen, or the record
        on a details page.
      * `:extra_records` — A 1-arity function taking the fetched result and
        returning records or `{resource, id}` pairs to also listen to. For
        values the walk cannot reach: an aggregate or an expression calculation
        is computed in SQL and materializes no record to name.
      * `:refetch_window` — Minimum ms between refetches. Defaults to
        `AshQuick.Config.refetch_window/0`.
      * `:subscribe` — A 1-arity function taking the fetched result and
        returning topics. Escape hatch: replaces the derivation entirely.
      * `:pub_sub` — Custom PubSub module (defaults to the endpoint).
    * `:filters` — Predefined filters, rendered as toggle buttons above the
      list. A list of maps with string keys `"name"`, `"label"` and
      `"expression"`, where the expression is anything `Ash.Query.filter/2`
      takes — a raw `Ash.Expr.expr(...)`, including one over a relationship
      path, or the map form:

          filters: [
            %{
              "name" => "needs_review",
              "label" => "Needs review",
              "expression" =>
                Ash.Expr.expr(state == :pending or latest_request.state == :pending)
            },
            %{"name" => "active", "label" => "Active", "expression" => %{"active" => %{"eq" => true}}}
          ]
    * `:print_templates` — A list of modules implementing `AshQuick.PrintTemplate`.
    * `:export_fields` — Fields to include in Excel/CSV exports. Falls back to
      `:list` fields, then all resource attributes.

  ### List options (under `:list`)

    * `:fields` — Fields shown in the list table. Can be atoms (`:name`) or
      nested relationship paths (`[seller: :name]`). Falls back to all
      resource attribute names. A bare relationship (`:seller`) renders as the
      destination's display label, so spell the path only when you want a
      field other than what that resource is called.
    * `:load` — Extra fields or relationships to load only for list queries.
      Combined with the top-level `:load` option.
    * `:default_action` — The read action used for listing. Defaults to the
      resource's lookup action (`AshQuick.Info.lookup_action/1`). Whatever it
      names is held to the same contract when this QuickView compiles: the list
      and its export pass the resource's search argument and page the answer,
      so the action has to take that argument, accept `nil` for it, and declare
      `pagination`.
    * `:new_action_label` — Label for the "Create" button (e.g. `"Add Product"`).
      When `nil`, the button is still shown but with a default label.
    * `:bulk_actions` — A function `(socket -> list)` returning custom bulk
      action definitions for the actions dropdown.

  ### Details options (under `:details`)

    * `:fields` — Fields shown in the detail view. Same format as list fields.
    * `:load` — Extra fields or relationships to load only for detail queries.
      Combined with the top-level `:load` option. Use this for heavy relationship
      loads that aren't needed in the list view.
    * `:default_action` — The read action used for details. Defaults to `:read`.
    * `:featured_actions` — A list of action **names** (e.g. `[:update, :destroy]`)
      to show as prominent buttons in the details header. All other authorized
      actions are placed in a "More actions" dropdown. Defaults to
      `[:update, :destroy]`.

  ### Form options (under `:form`)

    * `:widgets` — A map of `field_name => (assigns -> rendered)` overriding how
      individual fields render in the create/update forms. Create and update
      share one map; branch on `@form.action` inside the widget if they differ.

      Unlike list and details widgets — declared alongside a field in `:fields` —
      form widgets are keyed by name, because a form has no configurable field
      list: its fields are derived from the action's accepted attributes and
      arguments. A widget overrides **rendering only**; it cannot add a field the
      action does not take.

          form: [widgets: %{images: &__MODULE__.gallery/1}]

      The widget is a function component receiving the same assigns the built-in
      inputs get: `@field` (the Ash attribute, argument or relationship),
      `@phx_field` (the `Phoenix.HTML.FormField`), `@form` (the
      `AshPhoenix.Form`), `@uploads`, `@scope` and `@resource`. It is responsible
      for rendering its own inputs and errors.

      The key is the field's `name` as QuickView sees it — for a `belongs_to`
      that is the relationship (`:brand`), not the source attribute
      (`:brand_id`). Only the action's own fields are matched: fields inside an
      embedded sub-form render through the built-in inputs.

      Widgets may push their own events. Form events run through an
      `attach_hook` whose unmatched clause returns `{:cont, socket}`, so an event
      name QuickView does not handle reaches the QuickView module's own
      `handle_event/3`. Names QuickView *does* handle — `"validate"`, `"save"`,
      `"add-form"`, `"remove-form"`, `"cancel-upload"` — are halted at the hook
      and never reach the module, so a widget that needs to post-process one of
      those must use a name of its own and call the `AshPhoenix.Form` function
      itself.

  ## Action routing convention

  QuickView determines the view type from URL parameters:

    * `id: nil` + read action → **List view**
    * `id: <uuid>` + read action → **Details view**
    * `id: nil` + create action → **Create form**
    * `id: <uuid>` + update action → **Edit form**

  The action is resolved from (in priority order):
  1. The `action` URL parameter
  2. The `live_action` from the router (e.g. `:create`)
  3. The configured default action (`:index` for lists, `:read` for details)

  ## URL canonicalization

  Nothing in a query string is refused — `AshQuick.LiveView.URLParams` falls
  back to a value the page can render for anything that will not parse. At the
  first render the URL is then corrected to say what the page actually did, so
  a visitor holding `?limit=100000` lands on `?limit=250` rather than reading a
  URL that claims a page size they did not get. The patch uses `replace: true`,
  so Back still leads where they came from.

  Only the keys `URLParams` models survive it, so a query param of your own is
  dropped from the URL. This is what every control has always done — they
  rebuild the path from the parsed params alone — and the correction only makes
  it happen at first render rather than at the first click. Keep state you need
  in the session or in assigns rather than in a query param of your own.

  Only the query is corrected — never the path. A URL whose path the parsed
  params do not reproduce is left exactly as it came in, because rewriting a
  path is a navigation rather than a tidy-up. That covers `?action=`, which is
  priority 1 of the resolution order above and the only way to reach a second
  create-type action, and any id the URL percent-encodes.

  Left as typed too: a URL naming an action the resource does not have, which
  renders as not found with the URL as the evidence of what was asked for, and
  a URL a lifecycle hook has already redirected — see below.

  The correction is issued after `do_handle_params/4`, so that a host's own
  redirect wins rather than being raised over. The cost is that a URL needing
  correction runs its read action twice — once on the way in, once when the
  patch re-enters `handle_params/3`. Canonical URLs, which is all of them after
  the first patch, read once.

  ## Custom action templates

  You can override the rendering of any action by placing an HEEx template
  file named `action_<name>.html.heex` in the same directory as your QuickView
  module. For example:

      lib/my_app_web/live/orders/
      ├── order_quick.ex           # your QuickView module
      └── action_read.html.heex    # custom details template for :read action

  The template has access to all socket assigns including `@record`, `@resource`,
  `@params`, `@scope`, and `@options`. It also has `AshQuick.Components`
  imported (for `<.icon>`, `<.button>`, etc.) and `Phoenix.LiveView.JS` aliased.

  If you need components from your host application (e.g. `CoreComponents.table/1`),
  import them explicitly in your QuickView module:

      defmodule MyAppWeb.ExampleLive.Index do
        import MyAppWeb.CoreComponents
        use AshQuick.LiveView.QuickView, ...
      end

  ## Lifecycle hooks

  Two overridable hooks are available for customization:

    * `after_mount(socket, options)` — Called after the default mount logic.
      Use it to add custom assigns.
    * `after_handle_params(socket, options)` — Called after params are handled.
      Use it to redirect, add extra assigns, or modify behavior per-action.
      A redirect from here wins: URL canonicalization is skipped for that pass
      rather than fighting it.

  Example:

      defmodule MyAppWeb.ProfileLive.Quick do
        use AshQuick.LiveView.QuickView,
          resource: MyApp.Settings.User

        defp after_handle_params(%{assigns: %{path: "/profile"}} = socket, _options) do
          socket |> push_patch(to: "/profile/\#{socket.assigns.current_user.id}")
        end

        defp after_handle_params(socket, _options), do: socket
      end

  ## Sidebar

  By default, a QuickView renders the navigation sidebar: the entries of
  `AshQuick.Nav` the viewer can reach, grouped as the host declared them.

  Disable it with `sidebar: false`:

      use AshQuick.LiveView.QuickView,
        resource: MyApp.Catalog.Product,
        sidebar: false

  ### Sidebar labels and icons

  A QuickView needs no nav declaration to appear: it is discovered from the
  route `AshQuick.LiveView.Router.quick_view/3` declared for it, labelled
  from its resource's `plural_name` and drawn with a default icon. Declare an
  `entry` for it to say otherwise:

      defmodule MyAppWeb.Nav do
        use AshQuick.Nav

        nav do
          entry "/products", icon: "hero-cube-solid"
          entry "/profile", label: "My Profile", icon: {MyAppWeb.Icons, :profile}

          group "Catalog", ~w(/products /brands), icon: "hero-archive-box-solid"
        end
      end

  An icon is a heroicon class, a `{module, function}` naming a function
  component, or a one-argument function — the latter two free to render any
  markup. Anything left undeclared falls back to a generic icon.

  ## Resource conventions

  AshQuick asks the following of your Ash resources:

    * **The `AshQuick` extension** — Required, and a QuickView over a resource
      without it does not compile. The extension's transformers are what
      answer everything a QuickView asks of a resource: what a record is
      called, which fields a role may see, how a change reaches the page.
      Every resource a QuickView names needs it too — a bare relationship's
      destination, a dropdown's option list — not just the one the page is
      about.
    * **`:id` primary key** — Required. Used for URL routing, row selection,
      and record fetching.
    * **A lookup action** — Required of every resource a list page reads or a
      BelongsTo/HasMany dropdown searches, which is one read action asked the
      same question from four places: the list, its export and both dropdowns.
      It has to take the resource's search argument, accept `nil` for it (an
      unsearched read passes exactly that) and declare `pagination` — the list
      pages the answer and the dropdowns read `.results` off it. `:index` and
      `:search` by convention; a resource whose searchable read is named or
      shaped differently says so, and every reader resolves it from there:

          ash_quick do
            lookup do
              action :the_action
              search_argument :the_argument
            end
          end

      Nothing is generated for a resource that declares none — a search is how
      someone finds a record by a barcode or a code, not only by its name. The
      contract is checked instead, split on where reachability is known:
      `AshQuick.Lookup.Verifier` holds a declared action to all three
      requirements when the resource compiles, and this QuickView holds its
      list action and every dropdown destination it can reach to the same,
      catching an absence the resource-level verifier cannot judge. See
      `AshQuick.Info.lookup_action/1`.
    * **A display label** — Required. What a record is called in detail
      headers, BelongsTo/HasMany dropdowns, print file names and any field
      listing a bare relationship. Declared as
      `ash_quick do display do label :the_field end end`; undeclared, the
      extension fills it in with a `:display_name` field, then a `:name`
      attribute. A resource offering neither does not compile: an id is a
      uuid rather than a label, so one named by nothing it stores composes a
      label as a `:display_name` calculation. See
      `AshQuick.Info.display_label/1`.
    * **Activation** — Optional. A resource declaring
      `ash_quick do activation do enabled? true end end` gets dimmed rows for
      its inactive records, activate/deactivate row actions, and its inactive
      records withheld from dropdowns onto it. See `AshQuick.Info.activation/1`.

  ## Dependencies

  AshQuick requires the following dependencies in your project:

    * `ash` and `ash_phoenix` — Core Ash framework
    * `phoenix` and `phoenix_live_view` — Phoenix LiveView
    * `live_select` — Used for searchable dropdown and multi-select inputs
      in forms (BelongsTo, HasMany, Atom, and ArrayOfAtom fields)
    * Tailwind CSS — All components use Tailwind utility classes

  Optional dependencies (features are hidden when not available):

    * `exceed` + `nimble_csv` + `briefly` — Excel and CSV export
    * `chromic_pdf` + `merge_pdf` — PDF generation
    * `ex_aws` + `ex_aws_s3` — S3 storage for exports, prints, and image uploads
  """
  import Phoenix.Component, only: [assign: 3]
  alias Ash.Resource.Actions
  alias Phoenix.LiveView.JS
  alias AshQuick.LiveView.URLParams
  alias AshQuick.LiveView.QuickView.Options
  alias AshQuick.LiveView.QuickView
  alias AshQuick.LiveView.ListUtils
  alias AshQuick.LiveView.DetailsUtils
  alias AshQuick.LiveView.FormUtils
  alias AshQuick.LiveView.Liveness

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      use Phoenix.LiveView
      import Phoenix.Template, only: [embed_templates: 1]
      import AshQuick.Components
      import AshQuick.LiveView.URLParams, only: [path_for_page: 3]
      import AshQuick.LiveView.Components.PrintModal
      alias AshQuick.LiveView.Utils
      alias AshQuick.LiveView.URLParams
      alias Phoenix.LiveView.JS
      @before_compile AshQuick.LiveView.QuickView

      embed_templates "action_*.html", suffix: "_html"

      @resource opts[:resource]
      @options AshQuick.LiveView.QuickView.Options.new(__MODULE__, @resource, opts)

      @doc """
      The options this QuickView resolved at compile time.

      Exposed so the rules a QuickView has to satisfy can be checked across
      every one of them at once, rather than one page at a time as each is
      opened.
      """
      def __ash_quick_options__, do: @options

      @impl true
      def mount(params, session, socket) do
        socket =
          socket
          |> assign(options: @options)
          |> QuickView.do_mount(params, session, @options)
          |> after_mount(@options)

        {:ok, socket}
      end

      defp after_mount(socket, _options), do: socket

      @impl true
      def handle_params(params, url, socket) do
        socket = Liveness.unsubscribe_all(socket, @options)

        if connected?(socket) do
          uri = URI.parse(url)
          params = URLParams.from_url_params(params)
          action_name = QuickView.action_from_params(params, @options, socket.assigns.live_action)
          ash_action = Ash.Resource.Info.action(@options.resource, action_name)
          base_path = QuickView.base_path!(socket, uri)

          socket =
            socket
            |> assign(connected?: true)
            |> assign(:base_path, base_path)
            |> assign(
              :routed_shapes,
              AshQuick.LiveView.Router.served_shapes(socket.router, base_path)
            )
            |> assign(:path, uri.path)
            |> assign(:params, params)
            |> assign(:resource, @options.resource)
            |> assign(:ash_action, ash_action)

          # A URL naming an action the resource does not have resolves to no
          # action at all; it renders as not found rather than being handed to
          # callbacks that all expect one.
          socket =
            if ash_action do
              socket
              |> QuickView.do_handle_params(params, ash_action, @options)
              |> after_handle_params(@options)
            else
              socket
            end

          # The page renders what the query string *parsed* to, so the address
          # bar is made to say the same thing rather than keep the promise the
          # link made: a limit past the ceiling, a page before the first, a
          # filter that will not decode. Corrected at the first render or not
          # at all — that is the moment the visitor can still tie the link they
          # followed to the list they got, and by the time a control rebuilds
          # the path the evidence of what was dropped has gone with it.
          #
          # Only what `URLParams` models survives, so an unmodeled `?foo=bar`
          # is dropped here. That is not a new loss: every control has always
          # rebuilt the path from the parsed struct alone, so the first click
          # dropped it anyway. This only makes the library honest about it at
          # the render the visitor is looking at.
          #
          # The query is corrected; the path never is. `full_path/2` rebuilds
          # both, but a path derived from the parsed params is a navigation
          # rather than a tidy-up when it disagrees with the one being served —
          # see `correctable_query?/2`, which is what refuses those.
          #
          # Last, and only over a socket nothing else has redirected, because
          # `push_patch/2` *raises* on a socket already set to redirect rather
          # than overruling it. A host patching from `after_handle_params/2` —
          # `/profile` to `/profile/<id>` — would otherwise be taken down by a
          # query string it never looked at.
          canonical_path = URLParams.full_path(base_path, params)

          socket =
            if ash_action && is_nil(socket.redirected) &&
                 QuickView.correctable_query?(uri, canonical_path) do
              # `replace: true`: Back belongs to wherever the visitor came
              # from, not to the URL they were just moved off.
              push_patch(socket, to: canonical_path, replace: true)
            else
              socket
            end

          {:noreply, socket}
        else
          {:noreply, socket |> assign(connected?: false)}
        end
      end

      defp after_handle_params(socket, _options), do: socket

      defoverridable mount: 3
      defoverridable after_mount: 2
      defoverridable handle_params: 3
      defoverridable after_handle_params: 2
    end
  end

  defmacro __before_compile__(env) do
    env.module
    |> Module.get_attribute(:options)
    |> Liveness.verify_publishable!(env.module)

    if Module.defines?(env.module, {:render, 1}) do
      :ok
    else
      quote do
        @impl true
        def render(%{connected?: false} = var!(assigns)) do
          ~H"""
          <div class="flex flex-col h-full items-center justify-center p-8">
            <span class="loading loading-spinner loading-xl text-primary"></span>
          </div>
          """
        end

        def render(%{ash_action: nil} = assigns) do
          QuickView.render_unknown_action(assigns)
        end

        # sobelow_skip ["DOS.StringToAtom"]
        def render(assigns) do
          assigns =
            assigns
            |> QuickView.prepare_assigns(assigns.params, assigns.ash_action, @options)

          template_function_name = "action_#{assigns.ash_action.name}_html" |> String.to_atom()

          if function_exported?(__MODULE__, template_function_name, 1) and
               not QuickView.forbidden_form?(assigns) do
            apply(__MODULE__, template_function_name, [assigns])
          else
            assigns
            |> QuickView.do_render(assigns.params, assigns.ash_action)
          end
        end
      end
    end
  end

  @doc """
  The base path of the route currently being served.

  It is read from the route rather than from the QuickView so that the two
  cannot disagree: `AshQuick.LiveView.Router.quick_view/3` is what puts it
  there, and it is the same value the router matched on.
  """
  def base_path!(socket, %URI{} = uri) do
    case Phoenix.Router.route_info(socket.router, "GET", uri.path, uri.host) do
      %{ash_quick: %{base_path: base_path}} ->
        base_path

      _ ->
        raise """
        #{inspect(socket.view)} was reached at #{uri.path}, through a route that \
        carries no AshQuick metadata.

        QuickView routes must be declared with `quick_view/3`, which is what \
        pins the base path onto the route:

            import AshQuick.LiveView.Router

            quick_view "#{uri.path}", #{inspect(socket.view)}
        """
    end
  end

  @doc false
  # Whether `canonical_path` corrects `uri`'s query without moving the page.
  #
  # Public only because the generated `handle_params/3` calls it; it is an
  # internal detail of that callback rather than surface a host may rely on.
  #
  # Canonicalize the query, never the path. `full_path/2` rebuilds both, but
  # only the query is this function's to correct: the path it writes is from
  # the parsed params, and where that disagrees with the path actually being
  # served, rewriting it does not tidy the URL — it navigates.
  #
  # Two ways they disagree, both of them real:
  #
  #   * `?action=` is priority 1 of the action resolution order, and
  #     `quick_view/3` serves no `/<action>` route, so it is the only way to
  #     reach a second create-type action. `full_path/2` writes that action into
  #     the path, where it lands on `/:id` and renders a record that is not there.
  #   * An id the URL percent-encodes comes back raw from `full_path/2`, so the
  #     two never agree and the patch repeats forever.
  #
  # So the path is compared only to be left alone: when it differs, the URL came
  # in naming something this cannot rewrite, and is returned as typed.
  #
  # The query is compared as decoded maps, which is the only form the two sides
  # agree in — and a wrong comparison here is not a cosmetic bug but an endless
  # loop, since each patch is another request. Against the raw params map it
  # never settles: `URLParams` holds `limit` and `page` as integers where a query
  # holds strings.
  def correctable_query?(%URI{} = uri, canonical_path) when is_binary(canonical_path) do
    canonical = URI.parse(canonical_path)

    canonical.path == uri.path and
      URI.decode_query(uri.query || "") != URI.decode_query(canonical.query || "")
  end

  @doc """
  Renders the not-found page for a URL naming an action the resource lacks.

  The same page a missing record gets: the URL asked for something that is
  not there, and a mistyped one is a wrong turn rather than a fault worth
  reporting.
  """
  def render_unknown_action(assigns) do
    assigns
    |> assign(:record, nil)
    |> AshQuick.LiveView.Components.DetailsView.details_view()
  end

  def do_mount(socket, _params, _session, %Options{} = options) do
    socket
    # The layout renders the nav, so the option has to reach it from here — a
    # view is what knows it wants the width, and the layout is what wraps it.
    |> assign(:sidebar, options.sidebar)
    |> assign(:filters, options.filters)
    |> assign(:bulk_actions, options.bulk_actions && options.bulk_actions.(socket))
    |> assign(
      :resource_bulk_actions,
      ListUtils.resource_bulk_actions(options.resource, socket.assigns.scope, options)
    )
    |> assign(:action_running, false)
  end

  def do_handle_params(
        socket,
        %{id: nil} = params,
        %Actions.Read{get?: false} = action,
        %Options{} = options
      ) do
    ListUtils.do_handle_params(socket, params, action, options)
  end

  def do_handle_params(socket, %{id: _} = params, %Actions.Read{} = action, %Options{} = options) do
    DetailsUtils.do_handle_params(socket, params, action, options)
  end

  def do_handle_params(
        socket,
        %{id: nil} = params,
        %Actions.Create{} = action,
        %Options{} = options
      ) do
    FormUtils.do_handle_params(socket, params, action, options)
  end

  def do_handle_params(
        socket,
        %{id: _} = params,
        %Actions.Update{} = action,
        %Options{} = options
      ) do
    FormUtils.do_handle_params(socket, params, action, options)
  end

  def prepare_assigns(assigns, %{id: nil}, %Actions.Read{get?: false}, %Options{} = options) do
    # Computed once at mount (do_mount) — record-less Ash.can? is scope-dependent
    # only, so it must not be re-filtered on every render.
    resource_actions = assigns[:resource_bulk_actions] || []
    custom_actions = assigns[:bulk_actions] || []

    print_actions = build_print_actions(options.print_templates)

    assigns
    |> assign(:id, "#{Ash.Resource.Info.trace_name(options.resource)}-list")
    |> assign(:fields, options.list_fields)
    |> assign(:new_action_label, options.new_action_label)
    |> assign(:new_click, fn -> JS.push("new_click") end)
    |> assign(:actions, custom_actions ++ resource_actions)
    |> assign(:print_actions, print_actions)
    |> assign(:print_templates, options.print_templates)
    |> assign(:path_for_page, &URLParams.path_for_page(assigns.path, assigns.params, &1))
  end

  def prepare_assigns(assigns, %{id: id}, %Actions.Read{}, %Options{} = options) do
    print_actions = build_print_actions(options.print_templates)

    assigns
    |> assign(:id, "#{id}-details")
    |> assign(:fields, options.details_fields)
    |> assign(:print_actions, print_actions)
    |> assign(:print_templates, options.print_templates)
  end

  def prepare_assigns(assigns, %{id: nil}, %Actions.Create{}, %Options{} = options) do
    assigns
    |> assign(:id, "#{Ash.Resource.Info.trace_name(options.resource)}-create")
  end

  def prepare_assigns(assigns, %{id: id}, %Actions.Update{}, %Options{}) do
    assigns
    |> assign(:id, "#{id}-form")
  end

  defp build_print_actions(print_templates) do
    if AshQuick.Config.print_enabled?() do
      print_templates
      |> Enum.with_index()
      |> Enum.map(fn {template_mod, index} ->
        %{
          title: template_mod.label(),
          func: JS.push("print_pdf", value: %{template_index: index})
        }
      end)
    else
      []
    end
  end

  @doc """
  Whether a custom `action_*` form template must be skipped in favour of the
  generic form view.

  A custom template replaces `FormView.form_view/1` wholesale, including the
  `Ash.can?` gate every generic form gets for free — and nothing makes that
  omission visible. So the gate is applied here instead, at the dispatch: a
  template is skipped when its actor may not run the action, and the generic
  view renders the forbidden panel in its place. This also covers an update
  form whose record the actor cannot read, which `FormView.forbidden?/1`
  answers `true` for and whose template would deref the nil record.

  Read actions are gated by `DetailsView`, not `FormView`, so they are left
  to their custom templates.
  """
  def forbidden_form?(%{ash_action: %action_type{}} = assigns)
      when action_type in [Actions.Create, Actions.Update] do
    AshQuick.LiveView.Components.FormView.forbidden?(assigns)
  end

  def forbidden_form?(_assigns), do: false

  def do_render(assigns, %{id: nil}, %Actions.Read{get?: false}) do
    assigns
    |> AshQuick.LiveView.Components.ListView.list_view()
  end

  def do_render(assigns, %{id: id}, %Actions.Read{}) when not is_nil(id) do
    assigns
    |> AshQuick.LiveView.Components.DetailsView.details_view()
  end

  def do_render(assigns, _, _) do
    assigns
    |> AshQuick.LiveView.Components.FormView.form_view()
  end

  def action_from_params(%URLParams{action: action}, _config, _live_action)
      when not is_nil(action) do
    action
  end

  def action_from_params(%URLParams{id: nil}, _config, live_action)
      when not is_nil(live_action) do
    live_action
  end

  def action_from_params(%URLParams{id: nil}, %Options{} = options, nil) do
    options.list_default_action
  end

  def action_from_params(%URLParams{action: nil, id: id}, %Options{} = options, nil)
      when not is_nil(id) do
    options.details_default_action
  end
end
