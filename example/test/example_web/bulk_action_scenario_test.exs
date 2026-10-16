defmodule ExampleWeb.BulkActionScenarioTest do
  @moduledoc """
  Running one action over a selection of rows.

  A page that names nothing gets a **derived** menu: every public update and
  destroy that takes no input and that the actor may run. A page that passes
  `list: [bulk_actions: ...]` gets exactly what it names, in its order: action
  names, run through the modal, and custom items whose events the page handles
  itself. `ExampleWeb.ProductLive.Quick` names `:reprice`, which takes a price,
  next to the three actions a derived menu would have offered.

  Every named or derived action opens in the action modal over the list: a
  confirmation for one that takes no input, a form for one that does. The
  selection survives it, and Cancel runs nothing.

  The menu is also the clearest case of a control that is not there for two
  different reasons: nothing is selected, or the actor may not run it. Both are
  driven, because a `refute_has` that passes for the first reason would pass for
  the second whether or not the permission works.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  # The row actions share the menu's labels, so a bulk one is addressed by the
  # event it pushes rather than by its text.
  @bulk "a[phx-click*='bulk_action']"
  @modal "#ash-quick-action-modal"

  setup %{admin: admin} do
    %{
      first: product(name: "First tent", price: Money.new(:USD, "100.00"), actor: admin),
      second: product(name: "Second tent", price: Money.new(:USD, "50.00"), actor: admin),
      untouched: product(name: "Untouched tent", price: Money.new(:USD, "20.00"), actor: admin)
    }
  end

  describe "the menu" do
    test "appears only once something is selected", ctx do
      %{conn: conn, admin: admin, first: first} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      # Nothing ticked: there is no selection to act on, so there is no menu.
      |> refute_has(@bulk)
      |> tick_rows([first.id])
      |> assert_has(@bulk, text: "Deactivate")
    end

    test "is exactly what the page names, in its order", ctx do
      %{conn: conn, admin: admin, first: first} = ctx

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products")
        |> tick_rows([first.id])

      assert menu_titles(session) ==
               ["Reprice", "Discount 10%", "Activate", "Deactivate", "Delete"]
    end

    test "leaves out a derived action the page does not name", %{conn: conn, admin: admin} do
      record = guarded(unique("named-"))

      # `/test/bulk_named` names only `:destroy` and a custom item. `:seal` takes
      # no input, so a page naming nothing offers it (see the derived menu
      # below); naming the menu is how a page drops it.
      session =
        conn
        |> log_in(admin)
        |> visit("/test/bulk_named")
        |> tick_rows([record.id])

      assert menu_titles(session) == ["Delete", "Count them"]
      refute_has(session, @bulk, text: "Seal")
    end

    test "derived, offers every action that takes no input and none that does", ctx do
      %{conn: conn, admin: admin, editor: editor} = ctx

      # `ExampleWeb.UserLive.Quick` names no bulk actions. `:activate` and
      # `:deactivate` come from the activation declaration and `:destroy` is a
      # default; `:update` takes input, so whether one set of values makes
      # sense for every selected user is not something to guess.
      conn
      |> log_in(admin)
      |> visit(~p"/users")
      |> tick_rows([editor.id])
      |> assert_has(@bulk, text: "Deactivate")
      |> assert_has(@bulk, text: "Activate")
      |> assert_has(@bulk, text: "Delete")
      |> refute_has(@bulk, text: "Update")

      record = guarded(unique("derived-"))

      # A destroy that takes an argument is not derived either: it used to be,
      # and ran without the argument it needs.
      conn
      |> log_in(admin)
      |> visit("/test/bulk_guarded")
      |> tick_rows([record.id])
      |> assert_has(@bulk, text: "Delete")
      |> assert_has(@bulk, text: "Seal")
      |> refute_has(@bulk, text: "Retire")
    end

    test "leaves out an action a policy forbids on the bulk surface alone", ctx do
      %{conn: conn, admin: admin, editor: editor} = ctx

      # `:impersonate` is an input-less update on the actor resource, so it is
      # derived into this menu without `ExampleWeb.UserLive.Quick` naming it.
      # `Example.Accounts.User` forbids it under `:ash_quick_list_bulk`, and
      # that clause has to be what the menu is probed with — a bare `Ash.can?`
      # never carries the surface, so the policy would answer about a caller
      # that is not this one and the item would be offered.
      conn
      |> log_in(admin)
      |> visit(~p"/users")
      # A different user, so the refusal under test is the surface clause rather
      # than `forbid_if expr(id == ^actor(:id))`.
      |> tick_rows([editor.id])
      |> refute_has(@bulk, text: "Impersonate")
      # The menu is there and holding this resource's other derived actions, so
      # the refutal above is about the one action rather than about an empty
      # menu.
      |> assert_has(@bulk, text: "Deactivate")
      |> assert_has(@bulk, text: "Activate")
      |> assert_has(@bulk, text: "Delete")
    end

    test "a role the policy refuses is offered nothing over a selection", ctx do
      %{conn: conn, viewer: viewer, editor: editor, first: first} = ctx

      # A viewer writes nothing at all, so the menu has no contents and does not
      # render even with a row ticked.
      conn
      |> log_in(viewer)
      |> visit(~p"/products")
      |> tick_rows([first.id])
      |> refute_has(@bulk)
      |> refute_has("a", text: "Discount 10%")

      # An editor is the sharper case: they may deactivate, so the menu *is*
      # there — and the actions they may not run are the ones missing from it.
      # `:reprice` is named by the page and still left out: a named action is
      # offered as the actor's policy allows.
      conn
      |> log_in(editor)
      |> visit(~p"/products")
      |> tick_rows([first.id])
      |> assert_has(@bulk, text: "Deactivate")
      |> refute_has(@bulk, text: "Reprice")
      |> refute_has("a", text: "Discount 10%")
    end
  end

  describe "running one" do
    test "a derived action changes every selected row and nothing else", ctx do
      %{conn: conn, admin: admin, first: first, second: second, untouched: untouched} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> tick_rows([first.id, second.id])
      |> run_bulk("Deactivate")
      # The list re-reads itself, so the two rows are dimmed without a reload.
      |> assert_has("tr[id='#{first.id}'].opacity-50")
      |> assert_has("tr[id='#{second.id}'].opacity-50")
      |> refute_has("tr[id='#{untouched.id}'].opacity-50")

      refute Ash.reload!(first, authorize?: false).active
      refute Ash.reload!(second, authorize?: false).active
      assert Ash.reload!(untouched, authorize?: false).active
    end

    test "a derived action that writes every row reports nothing and clears the selection",
         ctx do
      %{conn: conn, admin: admin, first: first, second: second} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> tick_rows([first.id, second.id])
      |> run_bulk("Deactivate")
      |> refute_has("#flash-error")
      |> refute_has(@modal)
      |> refute_has(@bulk)

      refute Ash.reload!(first, authorize?: false).active
      refute Ash.reload!(second, authorize?: false).active
    end

    # `Product` is versioned. A row moved behind the page no longer matches the
    # lock, and the bulk write skips it without an error, so the page has to
    # compare what was written with what was selected to say anything at all.
    test "a derived action reports the rows it did not write and keeps them selected", ctx do
      %{conn: conn, admin: admin, first: first, second: second, untouched: untouched} = ctx

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products")
        |> tick_rows([first.id, second.id, untouched.id])

      move_behind_the_view(second)
      move_behind_the_view(untouched)

      session
      |> run_bulk("Deactivate")
      |> assert_has("#flash-error",
        text:
          "Deactivate applied to 1 of 3 selected rows. The other 2 rows were not changed " <>
            "and are still selected: check them and try again."
      )
      |> assert_has("input[name='#{second.id}'][checked]")
      |> assert_has("input[name='#{untouched.id}'][checked]")
      |> refute_has("input[name='#{first.id}'][checked]")

      refute Ash.reload!(first, authorize?: false).active
      assert Ash.reload!(second, authorize?: false).active
      assert Ash.reload!(untouched, authorize?: false).active
    end

    # Destroys take the lock too (#15), and a stale one is skipped the same way
    # rather than failing the batch. Pinned so an Ash change that turns it into
    # an error, which the error branches would then report, is noticed.
    test "a derived Delete skips a row moved behind the page and reports it", ctx do
      %{conn: conn, admin: admin, first: first, second: second} = ctx

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products")
        |> tick_rows([first.id, second.id])

      move_behind_the_view(second)

      session
      |> run_bulk("Delete")
      |> assert_has("#flash-error",
        text:
          "Delete applied to 1 of 2 selected rows. The other row was not changed " <>
            "and is still selected: check it and try again."
      )
      |> assert_has("input[name='#{second.id}'][checked]")

      assert {:error, _} = Ash.get(Example.Catalog.Product, first.id, authorize?: false)
      assert {:ok, _} = Ash.get(Example.Catalog.Product, second.id, authorize?: false)
    end

    test "a declared action runs the one the resource could not offer", ctx do
      %{conn: conn, admin: admin, first: first, second: second, untouched: untouched} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> tick_rows([first.id, second.id])
      |> click_link("a", "Discount 10%")
      |> assert_has("*", text: "Repriced 2 products.")

      assert Money.to_string!(Ash.reload!(first, authorize?: false).price) =~ "90"
      assert Money.to_string!(Ash.reload!(second, authorize?: false).price) =~ "45"
      assert Money.to_string!(Ash.reload!(untouched, authorize?: false).price) =~ "20"

      # It ran the real action, so the trail and the price-change log both have
      # it — which is the reason to reach for an action rather than a write.
      assert repriced_ids() == MapSet.new([first.id, second.id])
    end

    test "a declared action forged on the details page declines instead of crashing", ctx do
      %{conn: conn, admin: admin, first: first} = ctx

      # `quick_view/3` serves both routes from one module, and the details hook
      # passes a name it does not handle through exactly as the list's does. So
      # `"discount"` pushed at `/products/:id` reaches the same clause — on a
      # page that has neither a selection nor a list of results to read.
      conn
      |> log_in(admin)
      |> visit(~p"/products/#{first.id}")
      |> PhoenixTest.unwrap(fn view ->
        render_click(view, "discount", %{})
        render(view)
      end)
      # Still mounted and still showing the record, rather than an exit the
      # caller has to trap.
      |> assert_has("h1", text: first.name)

      # Nothing was repriced on the way past.
      assert Money.to_string!(Ash.reload!(first, authorize?: false).price) =~ "100"
      assert repriced_ids() == MapSet.new([])
    end

    test "the selection is cleared afterwards, so it cannot be run twice by accident", ctx do
      %{conn: conn, admin: admin, first: first} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> tick_rows([first.id])
      |> click_link("a", "Discount 10%")
      |> refute_has(@bulk)

      assert Money.to_string!(Ash.reload!(first, authorize?: false).price) =~ "90"
    end

    # A bulk action is a write per row rather than one transaction, so a refusal
    # partway through does not undo the rows that already went through. Stopping
    # at it only loses the fact that they did — which is the state an operator
    # then has to guess at.
    test "a row the lock refuses does not stop the rows it does not", ctx do
      %{conn: conn, admin: admin, first: first, second: second} = ctx

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products")
        |> tick_rows([first.id, second.id])

      # The page is holding both rows as they were at version 1. Moving one of
      # them out from under it is what the optimistic lock refuses, and it
      # refuses exactly one of the two rows the click is about to reprice.
      Ash.update!(second, %{description: "moved by somebody else"},
        actor: admin,
        authorize?: false
      )

      session
      |> click_link("a", "Discount 10%")
      |> assert_has("*", text: "Repriced 1 of 2 products.")
      |> assert_has("*", text: AshQuick.LiveView.ActionErrors.stale_message())

      # The row the lock let through is repriced, and said to be.
      assert Money.to_string!(Ash.reload!(first, authorize?: false).price) =~ "90"
      assert Money.to_string!(Ash.reload!(second, authorize?: false).price) =~ "50"
    end

    test "a second run does not discount a row the first one already did", ctx do
      %{conn: conn, admin: admin, first: first, second: second} = ctx

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products")
        |> tick_rows([first.id, second.id])

      Ash.update!(second, %{description: "moved by somebody else"},
        actor: admin,
        authorize?: false
      )

      # The selection that survives a partial run is the rows that did *not* go
      # through, so running it again is a retry rather than a second discount.
      # Keeping the whole selection would compound 10% onto the rows that
      # already took it — and the operator retrying a run that reported an
      # error has every reason to.
      session
      |> click_link("a", "Discount 10%")
      |> click_link("a", "Discount 10%")

      assert Money.to_string!(Ash.reload!(first, authorize?: false).price) =~ "90"
      refute Money.to_string!(Ash.reload!(first, authorize?: false).price) =~ "81"
    end

    test "an event forged without the button is refused by the policy behind it", ctx do
      %{conn: conn, editor: editor, first: first} = ctx

      # The editor has no "Discount 10%" link. Pushing the event anyway is what
      # somebody editing the DOM would do, and `:reprice`'s policy — not the
      # missing control — is what stops it.
      session =
        conn
        |> log_in(editor)
        |> visit(~p"/products")
        |> tick_rows([first.id])
        |> refute_has("a", text: "Discount 10%")

      PhoenixTest.unwrap(session, fn view -> render_click(view, "discount", %{}) end)

      session
      |> assert_has("*", text: AshQuick.LiveView.ActionErrors.forbidden_message())

      assert Money.to_string!(Ash.reload!(first, authorize?: false).price) =~ "100"
    end
  end

  describe "a confirmation" do
    test "names the action and the rows, and Cancel leaves them as they were", ctx do
      %{conn: conn, admin: admin, first: first, second: second} = ctx

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products")
        |> tick_rows([first.id, second.id])
        |> click_link(@bulk, "Deactivate")
        # Nothing ran on the click: it opened a confirmation over the list.
        |> assert_has("#{@modal} h3", text: "Deactivate")
        |> assert_has(@modal, text: "Applies to 2 selected rows.")
        |> assert_has("[inert] tr[id='#{first.id}']")
        # Locks while it runs, as the single confirmation does.
        |> assert_has("#{@modal} form[phx-hook='AshQuick.Components.SubmitLock']")

      assert Ash.reload!(first, authorize?: false).active

      session
      |> click_button("#{@modal} button", "Cancel")
      |> refute_has(@modal)
      |> assert_has("input[name='#{first.id}'][checked]")
      |> assert_has("input[name='#{second.id}'][checked]")
      |> refute_has("tr[id='#{first.id}'].opacity-50")

      assert Ash.reload!(first, authorize?: false).active
      assert Ash.reload!(second, authorize?: false).active
    end

    test "closes on ✕ without running either", ctx do
      %{conn: conn, admin: admin, first: first} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> tick_rows([first.id])
      |> click_link(@bulk, "Delete")
      |> click_link("#{@modal} a[aria-label='Close']", "")
      |> refute_has(@modal)
      |> assert_has("input[name='#{first.id}'][checked]")

      assert {:ok, _} = Ash.get(Example.Catalog.Product, first.id, authorize?: false)
    end

    test "for a delete, confirms with the delete's button", ctx do
      %{conn: conn, admin: admin, first: first} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> tick_rows([first.id])
      |> click_link(@bulk, "Delete")
      |> assert_has("#{@modal} button.btn-error", text: "Confirm")
      |> assert_has(@modal, text: "Applies to 1 selected row.")
    end

    test "derived on a page that names nothing, runs the same way", ctx do
      %{conn: conn, admin: admin, editor: editor, viewer: viewer} = ctx

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/users")
        |> tick_rows([editor.id, viewer.id])
        |> click_link(@bulk, "Deactivate")
        |> assert_has(@modal, text: "Applies to 2 selected rows.")
        |> click_button("#{@modal} button", "Cancel")
        |> assert_has("input[name='#{editor.id}'][checked]")
        |> assert_has("input[name='#{viewer.id}'][checked]")

      assert Ash.reload!(editor, authorize?: false).active

      session
      |> run_bulk("Deactivate")
      |> refute_has(@modal)
      |> assert_has("tr[id='#{editor.id}'].opacity-50")
      |> assert_has("tr[id='#{viewer.id}'].opacity-50")

      refute Ash.reload!(editor, authorize?: false).active
      refute Ash.reload!(viewer, authorize?: false).active
    end

    # A selected row the list no longer shows is one the run cannot see: it is
    # left alone, and counted among the rows that were not changed.
    test "runs only the selected rows the list is showing", ctx do
      %{conn: conn, admin: admin, first: first, second: second} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products?search=#{first.name}")
      |> tick_rows([first.id, second.id])
      |> click_link(@bulk, "Deactivate")
      |> assert_has(@modal, text: "Applies to 1 selected row.")
      |> click_button("#{@modal} button", "Confirm")
      |> assert_has("#flash-error",
        text:
          "Deactivate applied to 1 of 2 selected rows. The other row was not changed " <>
            "and is still selected: check it and try again."
      )

      refute Ash.reload!(first, authorize?: false).active
      assert Ash.reload!(second, authorize?: false).active
    end
  end

  describe "a form" do
    test "applies one set of values to every selected row", ctx do
      %{conn: conn, admin: admin, first: first, second: second, untouched: untouched} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> tick_rows([first.id, second.id])
      |> click_link(@bulk, "Reprice")
      |> assert_has("#{@modal} h2", text: "Reprice")
      |> assert_has(@modal, text: "Applies to 2 selected rows.")
      |> assert_has("#{@modal} label", text: "Price")
      # Only what the action takes: the generic update's fields are not here.
      |> refute_has("#{@modal} label", text: "Name")
      |> assert_has("#{@modal} form[phx-hook='AshQuick.Components.SubmitLock']")
      |> fill_in("#{@modal} input", "Price", with: "75.00")
      |> click_button("#{@modal} button", "Save")
      |> refute_has(@modal)
      |> refute_has("#flash-error")
      |> assert_has("tr[id='#{first.id}'] td", text: "75.00")
      |> assert_has("tr[id='#{second.id}'] td", text: "75.00")
      |> refute_has("tr[id='#{untouched.id}'] td", text: "75.00")

      assert Money.to_string!(Ash.reload!(first, authorize?: false).price) =~ "75"
      assert Money.to_string!(Ash.reload!(second, authorize?: false).price) =~ "75"
      assert Money.to_string!(Ash.reload!(untouched, authorize?: false).price) =~ "20"
      assert repriced_ids() == MapSet.new([first.id, second.id])
    end

    test "refuses a value the input cannot take, before anything runs", ctx do
      %{conn: conn, admin: admin, first: first} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> tick_rows([first.id])
      |> click_link(@bulk, "Reprice")
      |> fill_in("#{@modal} input", "Price", with: "not a price")
      |> assert_has("#{@modal} p.text-error")
      |> click_button("#{@modal} button", "Save")
      # Still open, the value still in it, and nothing run: a run refused by
      # Ash would say so in the flash rather than under the field.
      |> refute_has("#flash-error")
      |> assert_has("#{@modal} p.text-error")
      |> assert_has("#{@modal} input[value='not a price']")

      assert Money.to_string!(Ash.reload!(first, authorize?: false).price) =~ "100"
      assert repriced_ids() == MapSet.new([])
    end

    test "asks for a required input", ctx do
      %{conn: conn, admin: admin, first: first} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> tick_rows([first.id])
      |> click_link(@bulk, "Reprice")
      |> click_button("#{@modal} button", "Save")
      |> assert_has("#{@modal} p.text-error", text: "is required")
      |> refute_has("#flash-error")

      assert repriced_ids() == MapSet.new([])
    end

    # `:reprice` refuses an inactive product. That is a fact about a row, so the
    # form cannot know it while the price is typed — it asks no record — and
    # the run is what refuses. One refused row rolls the whole run back.
    test "a run one row refuses writes nothing, and keeps the modal and its values", ctx do
      %{conn: conn, admin: admin, first: first, second: second} = ctx

      Ash.update!(second, %{}, action: :deactivate, actor: admin)

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> tick_rows([first.id, second.id])
      |> click_link(@bulk, "Reprice")
      |> fill_in("#{@modal} input", "Price", with: "75.00")
      # Typed, and valid as a price: nothing about the inactive row shows yet.
      |> refute_has("#{@modal} p.text-error")
      |> click_button("#{@modal} button", "Save")
      |> assert_has("#flash-error", text: "Only an active product can be repriced.")
      |> assert_has("#{@modal} input[name='form[price]'][value*='75']")
      |> assert_has("input[name='#{first.id}'][checked]")

      assert Money.to_string!(Ash.reload!(first, authorize?: false).price) =~ "100"
      assert Money.to_string!(Ash.reload!(second, authorize?: false).price) =~ "50"
      assert repriced_ids() == MapSet.new([])
    end
  end

  describe "a forged event" do
    test "naming an action the menu does not offer opens nothing", ctx do
      %{conn: conn, admin: admin, editor: editor, first: first} = ctx

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products")
        |> tick_rows([first.id])

      # Not named and not derivable (`:update` takes input), a read, a create,
      # and a name the resource does not have at all.
      for name <- [:update, :read, :create, :index, :no_such_action] do
        session
        |> force_bulk_action(name)
        |> refute_has(@modal)
        |> assert_has("#flash-error", text: AshQuick.LiveView.ActionErrors.forbidden_message())
      end

      # Named by the page, and not allowed for this actor.
      conn
      |> log_in(editor)
      |> visit(~p"/products")
      |> tick_rows([first.id])
      |> force_bulk_action(:reprice)
      |> refute_has(@modal)
      |> assert_has("#flash-error", text: AshQuick.LiveView.ActionErrors.forbidden_message())

      record = guarded(unique("forged-"))

      # Derived on a page that names nothing, and left out by one that names
      # its menu.
      conn
      |> log_in(admin)
      |> visit("/test/bulk_named")
      |> tick_rows([record.id])
      |> force_bulk_action(:seal)
      |> refute_has(@modal)

      refute Ash.get!(Example.Test.BulkGuarded, record.id, authorize?: false).sealed
      assert Money.to_string!(Ash.reload!(first, authorize?: false).price) =~ "100"
    end

    test "with nothing selected opens nothing", %{conn: conn, admin: admin} do
      # The menu is drawn only over a selection, so this event was not clicked.
      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> force_bulk_action(:deactivate)
      |> refute_has(@modal)
      |> assert_has("#flash-error", text: AshQuick.LiveView.ActionErrors.forbidden_message())
    end

    test "submitting with no modal open runs nothing", ctx do
      %{conn: conn, admin: admin, first: first} = ctx

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> tick_rows([first.id])
      |> force_bulk_save(%{"price" => "1.00"})
      |> assert_has("#flash-error", text: AshQuick.LiveView.ActionErrors.forbidden_message())

      assert Money.to_string!(Ash.reload!(first, authorize?: false).price) =~ "100"
      assert Ash.reload!(first, authorize?: false).active
    end

    # `Example.Test.BulkGuarded` refuses `:seal` under the form source and
    # nowhere else: the menu, probed under `:ash_quick_list_bulk`, offers it.
    # The modal asks nothing of its own, so it is the run, stamped with the
    # form source, that refuses, and the modal stays open to say so.
    test "a run its stamp forbids is refused by the run", %{conn: conn, admin: admin} do
      record = guarded(unique("sealed-"))

      conn
      |> log_in(admin)
      |> visit("/test/bulk_guarded")
      |> tick_rows([record.id])
      |> click_link(@bulk, "Seal")
      |> click_button("#{@modal} button", "Confirm")
      |> assert_has("#flash-error", text: AshQuick.LiveView.ActionErrors.forbidden_message())
      |> assert_has("#{@modal} button", text: "Confirm")

      refute Ash.get!(Example.Test.BulkGuarded, record.id, authorize?: false).sealed
    end

    # `:stamp` runs on any row not coded "locked", which only the row can
    # answer: asked of no row at all, the policy says no. So the modal asks
    # nothing, and the run decides over the rows it was given.
    test "a rule that depends on the row is decided by the run", %{conn: conn, admin: admin} do
      first = guarded(unique("open-"))
      second = guarded(unique("open-"))
      locked = guarded("locked")

      conn
      |> log_in(admin)
      |> visit("/test/bulk_guarded")
      |> tick_rows([first.id, second.id])
      |> click_link(@bulk, "Stamp")
      |> refute_has(@modal, text: "Access Forbidden")
      |> click_button("#{@modal} button", "Confirm")
      |> refute_has(@modal)
      |> refute_has("#flash-error")
      # A selection holding a row the rule refuses is refused whole, as any
      # run one row of fails.
      |> tick_rows([locked.id])
      |> click_link(@bulk, "Stamp")
      |> click_button("#{@modal} button", "Confirm")
      |> assert_has("#flash-error", text: AshQuick.LiveView.ActionErrors.forbidden_message())
      |> assert_has("#{@modal} button", text: "Confirm")

      assert Ash.get!(Example.Test.BulkGuarded, first.id, authorize?: false).stamped
      assert Ash.get!(Example.Test.BulkGuarded, second.id, authorize?: false).stamped
      refute Ash.get!(Example.Test.BulkGuarded, locked.id, authorize?: false).stamped
    end

    test "a selected id the list does not hold is never acted on", ctx do
      %{conn: conn, admin: admin, first: first} = ctx

      # Another store's product: the admin reads every store, so it is a
      # store's editor who cannot see it.
      store = store(actor: admin)
      editor = user(:editor, actor: admin, store: store)
      own = product(name: unique("Own tent "), store: store, actor: admin)

      conn
      |> log_in(editor)
      |> visit(~p"/products")
      |> refute_has("tr[id='#{first.id}']")
      |> tick_rows([own.id, first.id])
      |> run_bulk("Deactivate")

      refute Ash.reload!(own, authorize?: false).active
      assert Ash.reload!(first, authorize?: false).active
    end
  end

  test "a bulk run is recorded as the form's, like every other run", ctx do
    %{conn: conn, admin: admin, first: first} = ctx

    conn
    |> log_in(admin)
    |> visit(~p"/products")
    |> tick_rows([first.id])
    |> run_bulk("Deactivate")

    assert [entry] =
             Example.Accounts.AuditLog
             |> Ash.Query.filter(resource_id == ^first.id and action_name == :deactivate)
             |> Ash.read!(authorize?: false)

    assert entry.context["action_source"] in ["ash_quick_form", :ash_quick_form]
  end

  # Opens the action from the menu and confirms it, which is what running an
  # input-less bulk action takes.
  defp run_bulk(session, title) do
    session
    |> click_link(@bulk, title)
    |> click_button("#{@modal} button", "Confirm")
  end

  defp menu_titles(%PhoenixTest.Live{view: view}) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#bulk-actions-menu li a")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp guarded(code) do
    Example.Test.BulkGuarded
    |> Ash.Changeset.for_create(:create, %{code: code})
    |> Ash.create!(authorize?: false)
  end

  # Bumps the version and tells nobody, so the page still holds the old one and
  # the optimistic lock no longer matches what it would write against.
  defp move_behind_the_view(record) do
    Ash.Seed.update!(record, %{version: record.version + 1})
  end

  # Ticking a row is a change on the list's own form, which is what the
  # checkboxes live in.
  defp repriced_ids do
    Example.Catalog.PriceChange
    |> Ash.read!(authorize?: false)
    |> MapSet.new(& &1.product_id)
  end
end
