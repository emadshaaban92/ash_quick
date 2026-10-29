defmodule ExampleWeb.LabelCatalogueScenarioTest do
  @moduledoc """
  Every label AshQuick hands the `:label_translator`, the ones it derives and
  the ones the pages write, is in the `labels.pot` `mix gettext.extract`
  writes from the `gettext` calls AshQuick gives the QuickViews, the router
  and the nav, so a translator working from that template leaves nothing on
  the page in English. CI fails while that template is stale.

  The translator here records what it is handed and returns it unchanged.
  The pages are the real ones: every QuickView's list and create form, and a
  product's details, update form, row menu, bulk menu and custom filter.

  Not async: the translator is application config, and every LiveView these
  tests start reads it.
  """
  use ExampleWeb.FeatureCase, async: false

  @template "priv/gettext/labels.pot"

  @drawn :label_catalogue_scenario_drawn

  defmodule Recorder do
    @moduledoc false
    def translate(label) do
      :ets.insert(:label_catalogue_scenario_drawn, {label})
      label
    end
  end

  setup do
    :ets.new(@drawn, [:named_table, :public, :set])
    original = Application.get_env(:ash_quick, :label_translator)
    Application.put_env(:ash_quick, :label_translator, {Recorder, :translate})

    on_exit(fn -> Application.put_env(:ash_quick, :label_translator, original) end)
  end

  test "the template holds every label the pages draw", %{conn: conn, admin: admin} do
    conn = log_in(conn, admin)
    product = product(tags: [:sale], description: "Sleeps four", actor: admin)

    paths = list_paths()
    assert "/products" in paths

    for path <- paths do
      {:ok, _view, _html} = live(conn, path)
    end

    # A create form draws every input of its action, nested forms included.
    for path <- paths, creates?(path) do
      {:ok, _view, _html} = live(conn, path <> "/create")
    end

    {:ok, view, _html} = live(conn, ~p"/products?search=#{product.sku}")

    view
    |> element(~s([id="#{product.id}-row-actions-dropdown"] [role="button"]))
    |> render_click()

    render_change(view, "table-form-change", %{product.id => "on"})
    {:ok, _view, _html} = live(conn, ~p"/products?show_custom_filter=true")
    {:ok, _view, _html} = live(conn, ~p"/products/#{product.id}")
    {:ok, _view, _html} = live(conn, ~p"/products/create")
    {:ok, _view, _html} = live(conn, ~p"/products/#{product.id}/update")

    drawn = @drawn |> :ets.tab2list() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    template =
      for %{msgid: msgid} <- Expo.PO.parse_file!(@template).messages,
          into: MapSet.new(),
          do: IO.iodata_to_binary(msgid)

    # The recorder saw the pages, so an empty difference is about the
    # template rather than about nothing having been drawn.
    assert MapSet.member?(drawn, "Products")
    assert MapSet.member?(drawn, "Reprice")

    # Labels the pages write: a `label:`, the `new_action_label`, a saved
    # filter, and a custom bulk item a function returns, which the page marks
    # with `dgettext_noop/2` itself.
    for label <- ["Brand", "Add Product", "On sale", "Discount 10%"] do
      assert MapSet.member?(drawn, label)
    end

    assert MapSet.difference(drawn, template) == MapSet.new()
  end

  defp creates?(path) do
    match?(
      %{phoenix_live_view: {_view, :create, _, _}},
      Phoenix.Router.route_info(ExampleWeb.Router, "GET", path <> "/create", nil)
    )
  end

  # The app's own pages: the test router also serves fixtures from
  # `test/support`, which the template, extracted in dev, never holds.
  defp list_paths do
    ExampleWeb.Router
    |> Phoenix.Router.routes()
    |> Enum.flat_map(fn
      %{metadata: %{ash_quick: %{base_path: path}, phoenix_live_view: {view, _, _, _}}} ->
        if page?(view), do: [path], else: []

      _route ->
        []
    end)
    |> Enum.uniq()
  end

  defp page?(view) do
    view.module_info(:compile)[:source]
    |> to_string()
    |> Path.relative_to(File.cwd!())
    |> String.starts_with?("lib/")
  end
end
