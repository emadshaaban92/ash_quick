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

  import Phoenix.LiveViewTest, only: [live: 2, element: 2, render: 1]

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
      #
      # Named by its action rather than taken off the front of the trail: the
      # reprice above left a second entry, and an unsorted read returns the two
      # of them in whatever order Postgres finds them.
      entry =
        AuditLog
        |> Ash.Query.filter(resource_id == ^product.id and action_name == :create)
        |> Ash.read_one!(authorize?: false)

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

  describe "a related record" do
    test "links to its page, with its hint, for a reader granted that page", ctx do
      %{conn: conn, admin: admin, brand: brand, category: category} = ctx

      store = store(name: "Harbour Street", actor: admin)

      product =
        product(name: "Trail tent", brand: brand, category: category, store: store, actor: admin)

      # `{[brand: :name], label: "Brand"}` reaches the brand's label and `:store`
      # stops at the relationship: both name a record, and both link it. Each
      # carries its resource's `display hint`, the code.
      conn
      |> log_in(admin)
      |> visit(~p"/products/#{product.id}")
      |> assert_has(related_link("brands", brand), text: brand.name)
      |> assert_has(related_link("stores", store), text: store.name)
      |> click_link(related_link("stores", store), store.name)
      |> assert_path(~p"/stores/#{store.id}")
    end

    test "is plain text, hint and all, for a reader without that page", ctx do
      %{conn: conn, admin: admin, editor: editor, brand: brand, category: category} = ctx

      store = store(name: "Harbour Street", actor: admin)

      product =
        product(name: "Trail tent", brand: brand, category: category, store: store, actor: admin)

      # An editor holds `/brands` but not `/stores`.
      conn
      |> log_in(editor)
      |> visit(~p"/products/#{product.id}")
      |> assert_has(related_link("brands", brand), text: brand.name)
      |> assert_has("[data-field='store'] dd", text: store.name)
      |> refute_has("[data-field='store'] a")
      |> refute_has("dd", text: store.code)
      |> refute_has("[data-field='store'] [title]")
    end

    test "links each record of a list", ctx do
      %{conn: conn, admin: admin, category: category} = ctx

      first = category(name: "Dome tents", parent: category, actor: admin)
      second = category(name: "Tunnel tents", parent: category, actor: admin)

      conn
      |> log_in(admin)
      |> visit(~p"/categories/#{category.id}")
      |> assert_has("[data-field='children'] a[href='/categories/#{first.id}']", text: first.name)
      |> assert_has("[data-field='children'] a[href='/categories/#{second.id}']",
        text: second.name
      )
      |> visit(~p"/categories/#{first.id}")
      |> assert_has("[data-field='parent.name'] a[href='/categories/#{category.id}']",
        text: category.name
      )
    end

    # The list renders the same fields without linking them.
    test "is not linked on a list page", ctx do
      %{conn: conn, admin: admin, product: product, brand: brand} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> assert_has("td", text: product.name)
      |> refute_has("td a[href='/brands/#{brand.id}']")
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

    test "links each writer to their page, with their hint as the tooltip", ctx do
      %{conn: conn, admin: admin, editor: editor, product: product} = ctx

      Ash.update!(product, %{name: "Four-season tent, revised"}, actor: editor)

      # `/users` is the only QuickView over `User`, so the path is derived; the
      # email is `User`'s declared hint.
      conn
      |> log_in(admin)
      |> visit(~p"/products/#{product.id}")
      |> assert_has("header a[href='/users/#{admin.id}'][title='#{admin.email}']",
        text: admin.name
      )
      |> assert_has("header a[href='/users/#{editor.id}'][title='#{editor.email}']",
        text: editor.name
      )
      |> assert_has(
        "header a[href='/users/#{editor.id}'][aria-label='#{editor.name} (#{editor.email})']"
      )
      |> click_link("header a[href='/users/#{editor.id}']", editor.name)
      |> assert_path(~p"/users/#{editor.id}")
    end

    test "names a writer bare for a reader who cannot open their page", ctx do
      %{conn: conn, admin: admin, editor: editor, product: product} = ctx

      # An editor holds `/products` but not `/users`, so gets neither the link
      # nor the email it carries.
      conn
      |> log_in(editor)
      |> visit(~p"/products/#{product.id}")
      |> assert_has("header", text: "Created by #{admin.name}")
      |> refute_has("header a[href^='/users']")
      |> refute_has("header [title='#{admin.email}']")
      |> refute_has("header [aria-label*='#{admin.email}']")
    end

    test "reads as one sentence per half, with nothing but the separator between", ctx do
      %{conn: conn, admin: admin, editor: editor, product: product} = ctx

      product = Ash.update!(product, %{name: "Four-season tent, revised"}, actor: editor)
      at = &AshQuick.Config.format_datetime/1

      {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/products/#{product.id}")

      # Exact, so whitespace the template leaves between the parts shows up.
      text =
        view
        |> element("header p > span")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert text ==
               "Created by #{admin.name} on #{at.(product.inserted_at)} · " <>
                 "Last updated by #{editor.name} on #{at.(product.updated_at)}"
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

      # `AuditLog` declares `inserted_by false` / `updated_by false`: writing the
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
      assert Ash.reload!(product, authorize?: false).inserted_by_id == ctx.admin.id
    end
  end

  defp related_link(base, record) do
    ~s{dd a[href="/#{base}/#{record.id}"][title="#{record.code}"]} <>
      ~s{[aria-label="#{record.name} (#{record.code})"]}
  end
end
