defmodule ExampleWeb.ActivationScenarioTest do
  @moduledoc """
  Activation is what a resource declares under `ash_quick do activation ... end`,
  and four behaviours hang off that declaration: a dimmed row, a withheld
  dropdown option, and the two row actions that flip the state — offered one at
  a time, since only one of them means anything to a given record.

  The last `describe` is the reason activation is *declared* rather than sniffed
  from the columns. A resource can carry an `:active` column that belongs to
  another extension entirely; reading the column instead of the declaration
  would filter those rows out of every dropdown onto them, silently, with the
  page otherwise healthy.
  """
  use ExampleWeb.FeatureCase, async: true

  alias AshQuick.LiveView.Utils
  alias Example.Catalog.{Brand, PriceChange}
  alias Example.Test.PlainBrand

  describe "a resource that declares activation" do
    setup %{admin: admin} do
      active = brand(name: "Northwind", actor: admin)
      inactive = brand(name: "Globex", actor: admin)
      Ash.update!(inactive, action: :deactivate, actor: admin)

      %{active_brand: active, inactive_brand: Ash.reload!(inactive, authorize?: false)}
    end

    # The dimming is the only thing on the list page that reads the attribute's
    # *value* rather than the resource's declaration, so it is also what proves
    # the list query loaded the column at all.
    test "dims its deactivated rows and leaves the active ones alone", ctx do
      ctx.conn
      |> log_in(ctx.admin)
      |> visit(~p"/brands")
      |> assert_has("tr[id='#{ctx.inactive_brand.id}'].opacity-50")
      |> refute_has("tr[id='#{ctx.active_brand.id}'].opacity-50")
    end

    # A deactivated record stays readable — it is listed above — but it can no
    # longer be picked for a new one. Driven on the product create form, where
    # both relationships are dropdowns onto resources that declare activation.
    test "withholds its deactivated records from a dropdown onto it", ctx do
      pickable = category(name: "Tents", actor: ctx.admin)
      retired = category(name: "Lanterns", actor: ctx.admin)
      Ash.update!(retired, action: :deactivate, actor: ctx.admin)

      session =
        ctx.conn
        |> log_in(ctx.admin)
        |> visit(~p"/products/create")

      categories = dropdown_entries(session, "Category")
      assert pickable.name in categories
      refute retired.name in categories

      brands = dropdown_entries(session, "Brand")
      assert ctx.active_brand.name in brands
      refute ctx.inactive_brand.name in brands
    end

    test "offers only the transition that means something, and running it flips the row", ctx do
      %{conn: conn, admin: admin, active_brand: active, inactive_brand: inactive} = ctx

      # An active record is offered `Deactivate` and not `Activate`; the
      # deactivated one the other way round. Both rows are on the same page, so
      # neither refutal can pass for want of a menu.
      conn
      |> log_in(admin)
      |> visit(~p"/brands")
      |> open_row_actions(active.id)
      |> assert_has("a[id='#{active.id}-action-deactivate']")
      |> refute_has("a[id='#{active.id}-action-activate']")
      |> open_row_actions(inactive.id)
      |> assert_has("a[id='#{inactive.id}-action-activate']")
      |> refute_has("a[id='#{inactive.id}-action-deactivate']")
      # One menu resolves at a time — opening the second put the first back to
      # its placeholder — so the row to be clicked is opened again.
      |> open_row_actions(active.id)
      # Clicking it dims the row it was clicked on, without a reload.
      |> click_link("a[id='#{active.id}-action-deactivate']", "Deactivate")
      |> assert_has("tr[id='#{active.id}'].opacity-50")

      refute Ash.reload!(active, authorize?: false).active
    end

    # Holding the route is not holding the policy: a viewer reads every brand
    # and writes none, so the row they can see offers them nothing.
    test "offers the actions only to a role whose policy allows them", ctx do
      %{conn: conn, viewer: viewer, active_brand: active} = ctx

      conn
      |> log_in(viewer)
      |> visit(~p"/brands")
      |> assert_has(row(active.id))
      |> open_row_actions(active.id)
      |> refute_has("a[id='#{active.id}-action-deactivate']")
      # A hidden link stops nobody from pushing the event behind it.
      |> force_row_action(active.id, :deactivate)

      assert Ash.reload!(active, authorize?: false).active
    end
  end

  describe "a resource that declares no activation" do
    # A price change is updatable by nobody — the resource defines no update
    # action at all — so its menu would be empty either way. The product's
    # brand is the comparison that carries weight, and it is in the describe
    # above. What is asserted here is the list side: no `Active` column, and no
    # dimming however the rows sit.
    test "has no active column and no dimmed rows", %{conn: conn, admin: admin} do
      product = product(name: "Four-season tent", actor: admin)
      reprice(product, to: Money.new(:USD, "149.00"), actor: admin)

      change = PriceChange |> Ash.read!(authorize?: false) |> hd()

      refute AshQuick.Info.activation?(PriceChange)

      conn
      |> log_in(admin)
      |> visit(~p"/price_changes")
      |> assert_has(row(change.id))
      |> refute_has("tr[id='#{change.id}'].opacity-50")
      |> refute_has("th", text: "Active")

      # And the resource that did declare it does draw the column, so the
      # refutal above is about the declaration rather than about the header
      # never being rendered by anything.
      conn
      |> log_in(admin)
      |> visit(~p"/brands")
      |> assert_has("th", text: "Active")
    end
  end

  describe "a resource carrying an :active column it never declared" do
    # No resource in this application disagrees with its own column, so the
    # disagreement is built. `Example.Test.PlainBrand` reads the brands
    # table and carries the same `:active`, and declares no activation — so one
    # row, deactivated once, can be read through both.
    #
    # Reading the column instead of the declaration is the mistake this pins:
    # it would drop another extension's rows out of every dropdown onto them,
    # silently, with the page otherwise healthy.
    test "keeps a deactivated record that the declaring resource drops", %{admin: admin} do
      assert Ash.Resource.Info.attribute(PlainBrand, :active),
             "the fixture lost its :active column — this test no longer pins anything"

      refute AshQuick.Info.activation?(PlainBrand)
      assert AshQuick.Info.activation?(Brand)

      retired = brand(actor: admin)
      Ash.update!(retired, action: :deactivate, actor: admin)

      # The same row, through the same function every dropdown calls.
      refute retired.id in dropdown_ids(Brand, admin)
      assert retired.id in dropdown_ids(PlainBrand, admin)
    end

    defp dropdown_ids(resource, actor) do
      resource
      |> Ash.Query.new()
      |> Utils.filter_inactive()
      |> Ash.read!(actor: actor, authorize?: false)
      |> Enum.map(& &1.id)
    end
  end
end
