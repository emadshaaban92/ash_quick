defmodule ExampleWeb.DetailsScenarioTest do
  @moduledoc """
  A details page is three things the resource decides and the view is not told:
  what the record is called, who wrote it, and which of its actions this reader
  may run.

  None of them is configured in `ExampleWeb.ProductLive.Quick` or its siblings.
  The title comes from the `display` label — declared, or inferred from a `name`
  / `display_name` field. The subtitle comes from the `bookkeeping` block, and
  each of its two halves is independently absent. The buttons come from
  `Ash.can?` over every update and destroy action the resource defines, split by
  `details: [featured_actions: ...]`.

  So all three are driven here rather than asserted against the declarations
  they are derived from.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  alias Example.Accounts.AuditLog
  alias Example.Catalog.{PriceChange, Product}

  setup %{admin: admin} do
    brand = brand(name: "Northwind Outfitters", actor: admin)
    category = category(name: "Tents", actor: admin)

    %{
      brand: brand,
      category: category,
      product: product(name: "Four-season tent", brand: brand, category: category, actor: admin)
    }
  end

  describe "the title" do
    test "is what the record is called, by whichever route resolved that", ctx do
      %{conn: conn, admin: admin, product: product} = ctx

      # Inferred from `:name`, which the resource declares no `display` block
      # for — the zero-config case.
      conn
      |> log_in(admin)
      |> visit(~p"/products/#{product.id}")
      |> assert_has("h1", text: product.name)
      |> refute_has("h1", text: product.id)

      # Declared: `Example.Accounts.User` names `:name` explicitly.
      conn
      |> log_in(admin)
      |> visit(~p"/users/#{admin.id}")
      |> assert_has("h1", text: admin.name)

      # Declared as something that is not a name at all.
      object = file_object(actor: admin)

      conn
      |> log_in(admin)
      |> visit(~p"/file_objects/#{object.id}")
      |> assert_has("h1", text: object.key)
    end

    test "can be a calculation, including one that reaches through a relationship", ctx do
      %{conn: conn, admin: admin, product: product} = ctx

      reprice(product, to: Money.new(:USD, "149.00"), actor: admin)
      change = PriceChange |> Ash.read!(authorize?: false) |> hd()

      # `PriceChange` has no naming field of its own: its `:display_name`
      # calculation is `expr(product.name)`, so a row is read as the repricing
      # *of* something.
      conn
      |> log_in(admin)
      |> visit(~p"/price_changes/#{change.id}")
      |> assert_has("h1", text: product.name)

      # And `AuditLog` composes two of its own columns into one. The calculation
      # runs in SQL, so it joins the stored atoms as they sit — the list page's
      # humanized "Create" is a render-time nicety the title does not share.
      entry =
        AuditLog
        |> Ash.Query.filter(resource_id == ^product.id)
        |> Ash.read!(authorize?: false)
        |> hd()

      conn
      |> log_in(admin)
      |> visit(~p"/audit_logs/#{entry.id}")
      |> assert_has("h1", text: "create product")
    end
  end

  describe "a field that stops at a relationship" do
    test "renders the destination's label rather than its id", ctx do
      %{conn: conn, admin: admin, product: product} = ctx

      reprice(product, to: Money.new(:USD, "149.00"), actor: admin)
      change = PriceChange |> Ash.read!(authorize?: false) |> hd()

      # `ExampleWeb.PriceChangeLive.Quick` lists `:product` bare — no path, no
      # label. The column heading is humanized from the relationship name and
      # the cell is the product's display label.
      conn
      |> log_in(admin)
      |> visit(~p"/price_changes")
      |> assert_has("th", text: "Product")
      |> assert_has("td", text: product.name)
      |> refute_has("td", text: product.id)
      |> visit(~p"/price_changes/#{change.id}")
      |> assert_has("dd", text: product.name)
      |> refute_has("dd", text: product.id)
    end
  end

  describe "the bookkeeping header" do
    test "names both writers once a second person has touched the record", ctx do
      %{conn: conn, admin: admin, editor: editor, product: product} = ctx

      # Created by the admin in `setup`, updated by the editor here, so the two
      # halves cannot both be satisfied by the same name.
      Ash.update!(product, %{name: "Four-season tent, revised"}, actor: editor)

      conn
      |> log_in(admin)
      |> visit(~p"/products/#{product.id}")
      |> assert_has("*", text: "Created by #{admin.name}")
      |> assert_has("*", text: "Last updated by #{editor.name}")
    end

    test "an append-only resource carries no last-updated half", ctx do
      %{conn: conn, admin: admin, product: product} = ctx

      reprice(product, to: Money.new(:USD, "149.00"), actor: admin)
      change = PriceChange |> Ash.read!(authorize?: false) |> hd()

      # `PriceChange` declares `updated_at false` and `updated_by false`, so
      # there is no second sentence to render — not an empty one.
      conn
      |> log_in(admin)
      |> visit(~p"/price_changes/#{change.id}")
      |> assert_has("*", text: "Created by #{admin.name}")
      |> refute_has("*", text: "Last updated")
    end

    test "a resource nobody writes through renders both halves without names", ctx do
      %{conn: conn, admin: admin, product: product} = ctx

      entry =
        AuditLog
        |> Ash.Query.filter(resource_id == ^product.id)
        |> Ash.read!(authorize?: false)
        |> hd()

      # `AuditLog` declares `created_by false` / `updated_by false`: writing the
      # row *is* the act, and the actor of the write it records is a column of
      # its own. Both timestamps remain, so both sentences render actorless.
      conn
      |> log_in(admin)
      |> visit(~p"/audit_logs/#{entry.id}")
      |> assert_has("*", text: "Created on")
      |> refute_has("*", text: "Created by")
    end
  end

  describe "the action buttons" do
    test "featured actions are buttons and everything else is behind the overflow", ctx do
      %{conn: conn, admin: admin, product: product} = ctx

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products/#{product.id}")
        # `details: [featured_actions: ...]` defaults to `[:update, :destroy]`,
        # and neither is named anywhere in `ExampleWeb.ProductLive.Quick`.
        |> assert_has("button", text: "Update")
        |> assert_has("button", text: "Delete")
        |> assert_has("#details-more-actions-dropdown")

      # `:reprice` is the resource's own named update, and `:deactivate` is
      # generated by the activation declaration. Both are offered, neither is
      # featured.
      session
      |> within("#details-more-actions-dropdown", &assert_has(&1, "a", text: "Reprice"))
      |> within("#details-more-actions-dropdown", &assert_has(&1, "a", text: "Deactivate"))
      # The record is active, so the transition it is already in is not offered.
      |> within("#details-more-actions-dropdown", &refute_has(&1, "a", text: "Activate"))
    end

    test "a reader whose policy forbids them all gets neither a button nor a menu", ctx do
      %{conn: conn, viewer: viewer, product: product} = ctx

      conn
      |> log_in(viewer)
      |> visit(~p"/products/#{product.id}")
      # Matched on the controls rather than on their words: "Updated At" is a
      # field label on this very page, so `refute_has("*", text: "Update")`
      # would pass for the wrong reason.
      |> assert_has("h1", text: product.name)
      |> refute_has("button", text: "Update")
      |> refute_has("button", text: "Delete")
      |> refute_has("#details-more-actions-dropdown")
    end
  end

  describe "the audit trail behind a page" do
    test "records an edit against the editor and the address it came from", ctx do
      %{conn: conn, editor: editor, product: product} = ctx

      conn
      |> log_in(editor)
      |> visit(~p"/products/#{product.id}")
      |> click_button("Update")
      |> fill_in("Name", with: "Three-season tent")
      |> click_button("Save")
      |> assert_has("h1", text: "Three-season tent")

      entry =
        AuditLog
        |> Ash.Query.filter(resource_id == ^product.id and action_name == :update)
        |> Ash.read_one!(authorize?: false, load: [:actor])

      assert entry.actor.id == editor.id
      assert entry.resource_name == Ash.Resource.Info.short_name(Product)
      assert entry.action_type == :update
      assert entry.attributes["name"] == "Three-season tent"

      # The address the socket connected from, which only `AshQuick.LiveView.Mount`
      # can know — the resource never sees a connection.
      assert entry.ip == "127.0.0.1"

      # And the actor is the one at the keyboard rather than the record's
      # creator, who is still named by the bookkeeping column.
      assert Ash.reload!(product, authorize?: false).created_by_id == ctx.admin.id
    end
  end
end
