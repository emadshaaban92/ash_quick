defmodule ExampleWeb.LabelCatalogueScenarioTest do
  @moduledoc """
  Every label a page hands the `:label_translator` is in the catalogue
  `mix ash_quick.gen.gettext` writes, so a translator working from that
  template leaves nothing on the page in English.

  The translator here records what it is handed and returns it unchanged.
  The pages are the real ones: every QuickView's list and create form, and a
  product's details, update form, row menu, bulk menu and custom filter.

  Not async: the translator is application config, and every LiveView these
  tests start reads it.
  """
  use ExampleWeb.FeatureCase, async: false

  alias AshQuick.Labels.Catalogue

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

  test "the catalogue holds every label the pages draw", %{conn: conn, admin: admin} do
    conn = log_in(conn, admin)
    product = product(tags: [:sale], description: "Sleeps four", actor: admin)

    paths = list_paths()
    assert length(paths) > 20

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
    catalogue = Catalogue.labels() |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    # The recorder saw the pages, so an empty difference is about the
    # catalogue rather than about nothing having been drawn.
    assert MapSet.member?(drawn, "Products")
    assert MapSet.member?(drawn, "Reprice")

    # The one thing the catalogue cannot read: what the product page's
    # `bulk_actions` function returns, which needs a socket.
    assert MapSet.difference(drawn, catalogue) == MapSet.new(["Discount 10%"])
  end

  defp creates?(path) do
    match?(
      %{phoenix_live_view: {_view, :create, _, _}},
      Phoenix.Router.route_info(ExampleWeb.Router, "GET", path <> "/create", nil)
    )
  end

  defp list_paths do
    ExampleWeb.Router
    |> Phoenix.Router.routes()
    |> Enum.flat_map(fn
      %{metadata: %{ash_quick: %{base_path: path}}} -> [path]
      _route -> []
    end)
    |> Enum.uniq()
  end
end
