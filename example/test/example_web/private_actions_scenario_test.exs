defmodule ExampleWeb.PrivateActionsScenarioTest do
  @moduledoc """
  An action the resource keeps for its own code, reached from a page.

  `Example.Catalog.Product` declares `:reindex` with `public? false`, and lets
  every call to it through with the `private_action?()` bypass Ash documents
  for internal actions. So no policy stands between it and whoever names it,
  and the page has to refuse it on `public?` alone: on every menu that lists
  actions, on every event that names one, and on every URL that resolves one.

  `:reindex` is the sharpest case there is. It takes no input, so going by type
  alone would offer it on every row and derive it into the bulk menu.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  alias Example.Accounts.AuditLog

  @bulk "a[phx-click*='bulk_action']"

  setup %{admin: admin} do
    %{product: product(name: "Four-season tent", actor: admin)}
  end

  test "the action is real, and running it leaves an audit entry", ctx do
    %{admin: admin, product: product} = ctx

    # The control for every refutal below: if `:reindex` ran, this is the
    # trace it would leave.
    product
    |> Ash.Changeset.for_update(:reindex, %{}, actor: admin)
    |> Ash.update!()

    assert [_entry] = reindexes_of(product.id)
  end

  describe "it is not offered" do
    test "on a row", %{conn: conn, admin: admin, product: product} do
      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> open_row_actions(product.id)
      |> refute_has("a[id='#{product.id}-action-reindex']")
      # The menu is open and holding the product's public actions.
      |> assert_has("a[id='#{product.id}-action-update']")
    end

    test "over a selection", %{conn: conn, admin: admin, product: product} do
      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> tick_rows([product.id])
      |> refute_has(@bulk, text: "Reindex")
      |> assert_has(@bulk, text: "Delete")
    end

    test "on the details page", %{conn: conn, admin: admin, product: product} do
      conn
      |> log_in(admin)
      |> visit(~p"/products/#{product.id}")
      |> refute_has("button", text: "Reindex")
      |> refute_has("a", text: "Reindex")
      |> assert_has("button", text: "Update")
    end
  end

  describe "it is refused when named anyway" do
    test "by a row event on the list", %{conn: conn, admin: admin, product: product} do
      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> force_row_action(product.id, :reindex)

      assert reindexes_of(product.id) == []
    end

    test "by a row event on the details page", %{conn: conn, admin: admin, product: product} do
      conn
      |> log_in(admin)
      |> visit(~p"/products/#{product.id}")
      |> force_row_action(product.id, :reindex)

      assert reindexes_of(product.id) == []
    end

    test "by a bulk event", %{conn: conn, admin: admin, product: product} do
      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> tick_rows([product.id])
      |> force_bulk_action(:reindex)

      assert reindexes_of(product.id) == []
    end

    test "by a URL", %{conn: conn, admin: admin, product: product} do
      conn = log_in(conn, admin)

      for url <- [~p"/products/#{product.id}/reindex", ~p"/products/#{product.id}?action=reindex"] do
        {:ok, view, _html} = live(conn, url)

        assert has_element?(view, "h1", "404")
      end

      # The same URL shape still serves the product's public update. The page
      # carries random ids and tokens, so "404" anywhere in it is no signal.
      {:ok, view, html} = live(conn, ~p"/products/#{product.id}/update")
      refute has_element?(view, "h1", "404")
      assert html =~ "Four-season tent"
    end
  end

  defp reindexes_of(product_id) do
    AuditLog
    |> Ash.Query.filter(resource_id == ^product_id and action_name == :reindex)
    |> Ash.read!(authorize?: false)
  end
end
