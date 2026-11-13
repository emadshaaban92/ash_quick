defmodule ExampleWeb.LivenessScenarioTest do
  @moduledoc """
  A QuickView refetches for the records it is showing, and a list announces the
  ones it is not.

  Ash publishes both `"product:<id>"` and the bare `"product"` for every write.
  A details page listens on the per-record topics it derives from what it holds.
  A list listens on the bare topic of its own resource, since it must hear about
  records it is not showing, but re-reads its rows only for a write to one of
  them (or to a record one of them shows); any other write only asks whether
  the "new records" bar should go up.

  Both directions are asserted on the same page every time. Neither half means
  anything alone: a page that is simply broken passes every `refute`, and a page
  that refetches on everything passes every `assert`.

  The probe is an `Ash.Seed.update!` rename. It writes the column without firing
  a notification, so the new name is invisible until *something else* causes a
  refetch — and then it is the refetch, and only the refetch, that could have
  surfaced it.

  `async: false`: `:refetch_window` coalesces refetches and is application env,
  so zeroing it is a global swap. At the 5s default the refetch under test lands
  long after the assertion.
  """
  use ExampleWeb.FeatureCase, async: false

  import ExUnit.CaptureLog

  alias Example.Accounts.AuditLog
  alias Example.Catalog.{Brand, Category, PriceChange, Product}
  alias Phoenix.Socket.Broadcast

  # The bulk menu shares its labels with the row menu, so a bulk action is
  # addressed by the event it pushes rather than by its text.
  @bulk "a[phx-click*='bulk_action']"
  @modal "#ash-quick-action-modal"

  setup do
    # Deleted rather than restored as `nil` on the way out: the key is not in
    # `config.exs` at all and `AshQuick.Config.refetch_window/0` reads its
    # default through `Application.get_env/3`, which an explicit `nil` would
    # satisfy — leaving every later test in the run with no window.
    previous = Application.fetch_env(:ash_quick, :refetch_window)
    Application.put_env(:ash_quick, :refetch_window, 0)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_quick, :refetch_window, value)
        :error -> Application.delete_env(:ash_quick, :refetch_window)
      end
    end)
  end

  describe "a list" do
    test "refetches for a row on screen and ignores one that is not", %{conn: conn, admin: admin} do
      on_screen = product(name: "On screen", actor: admin)
      off_screen = product(name: "Off screen", actor: admin)

      # Searched by sku, so a rename cannot drop the row out of the list and
      # confuse "gone" with "not refetched".
      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products?search=#{on_screen.sku}")
        |> assert_has("td", text: "On screen")

      renamed = rename_behind_the_view(on_screen)

      # A real write to a record this page is not holding. The page hears it on
      # the resource's topic, but only asks whether it belongs on the page — it
      # does not re-read the rows it holds.
      Ash.update!(off_screen, action: :deactivate, actor: admin)

      session
      |> refute_has("td", text: renamed.name)
      |> assert_has("td", text: "On screen")

      # The same write to the record it *is* holding.
      Ash.update!(on_screen, action: :deactivate, actor: admin)

      session
      |> assert_has("td", text: renamed.name)
      |> assert_has("tr[id='#{on_screen.id}'].opacity-50")
    end
  end

  describe "a list's refetch" do
    test "keeps a row deleted elsewhere in its place, as No longer available", ctx do
      %{conn: conn, admin: admin} = ctx

      first = product(name: "A first", actor: admin)
      second = product(name: "B second", actor: admin)
      third = product(name: "C third", actor: admin)

      # Two rows a page, so a refetch that closed the gap would pull the third
      # one up from the next page.
      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products?limit=2")
        |> assert_has("td", text: first.name, exact: true)

      Ash.destroy!(first, actor: admin)

      session
      |> assert_has("tr[id='#{first.id}'][data-gone] td", text: "No longer available")
      |> refute_has("td", text: first.name, exact: true)
      |> refute_has("#select_row_#{first.id}")
      |> assert_has("tr[id='#{second.id}'] td", text: second.name, exact: true)
      |> refute_has("td", text: third.name, exact: true)
      |> refute_has("#list-news")
    end

    test "drops a ticked row deleted elsewhere from the selection", ctx do
      %{conn: conn, admin: admin} = ctx

      kept = product(name: "Kept", actor: admin)
      gone = product(name: "Deleted elsewhere", actor: admin)

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products")
        |> tick_rows([gone.id])
        |> assert_has("#bulk-actions-menu")

      Ash.destroy!(gone, actor: admin)

      # The only ticked row, so nothing is selected any more and the bulk menu,
      # which would act on nothing, goes with it.
      session
      |> assert_has("tr[id='#{gone.id}'][data-gone]")
      |> assert_has("td", text: kept.name, exact: true)
      |> refute_has("#bulk-actions-menu")
    end

    test "keeps a row edited out of the search in its place, as No longer available", ctx do
      %{conn: conn, admin: admin} = ctx

      matching = product(name: "Findable one", actor: admin)
      leaving = product(name: "Findable two", actor: admin)

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products?search=Findable")
        |> assert_has("td", text: leaving.name, exact: true)

      Ash.update!(leaving, %{name: "Renamed away"}, action: :update, actor: admin)

      # Edited out of the search and unreadable look the same from here, so the
      # placeholder claims neither.
      session
      |> assert_has("tr[id='#{leaving.id}'][data-gone] td",
        text: "No longer available"
      )
      |> refute_has("td", text: "Renamed away", exact: true)
      |> assert_has("td", text: matching.name, exact: true)
    end

    test "keeps the order it drew, even when a write would re-sort it", ctx do
      %{conn: conn, admin: admin} = ctx

      first = product(name: "A first", actor: admin)
      second = product(name: "B second", actor: admin)

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products")

      # Sorted by name, "Z" would move below the second row on a fresh read.
      Ash.update!(first, %{name: "Z first"}, action: :update, actor: admin)

      session
      |> assert_has("tbody tr:first-child td", text: "Z first", exact: true)
      |> assert_has("tbody tr:nth-child(2) td", text: second.name, exact: true)
    end

    test "announces a record created elsewhere, and shows it on Reload", ctx do
      %{conn: conn, admin: admin} = ctx

      shown = product(name: "Already listed", actor: admin)

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products")
        |> assert_has("td", text: shown.name, exact: true)
        |> refute_has("#list-news")

      later = product(name: "Created afterwards", actor: admin)

      # Announced, not inserted: a row appearing under the pointer is a click
      # on the wrong record.
      session
      |> assert_has("#list-news", text: "This list has new records.")
      |> refute_has("td", text: later.name, exact: true)
      |> click_button("#list-news button", "Reload")
      |> refute_has("#list-news")
      |> assert_has("td", text: later.name, exact: true)
      |> assert_has("td", text: shown.name, exact: true)
    end

    test "comes alive when it was empty", ctx do
      %{conn: conn, admin: admin} = ctx

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products")
        |> refute_has("#list-news")

      product(name: "The first one", actor: admin)

      assert_has(session, "#list-news")
    end

    test "announces nothing for a record outside its search", ctx do
      %{conn: conn, admin: admin} = ctx

      shown = product(name: "Findable", actor: admin)

      # By sku, so the rename below keeps the row in the search.
      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products?search=#{shown.sku}")
        |> assert_has("td", text: shown.name, exact: true)

      product(name: "Something else", actor: admin)

      # The create reached the page; the reader's own first-page read is what
      # says it does not belong on it. Renaming the shown row proves the page
      # has refetched since.
      renamed = rename_behind_the_view(shown)
      Ash.update!(shown, action: :deactivate, actor: admin)

      session
      |> assert_has("td", text: renamed.name)
      |> refute_has("#list-news")
    end
  end

  describe "a list's related records" do
    # A row can show a record of the list's own resource: a category's
    # parent. The bare topic alone would make it a record off screen, so the
    # list also holds that record's own topic.
    test "a row showing a same-resource parent follows the parent's rename", ctx do
      %{conn: conn, admin: admin} = ctx

      parent = category(name: "Parent original", actor: admin)
      child = category(name: "Child row", parent: parent, actor: admin)

      session =
        conn
        |> log_in(admin)
        |> visit("/categories?search=#{child.code}")
        |> assert_has("td", text: "Parent original", exact: true)
        |> refute_has("td", text: parent.code, exact: true)

      Category.update!(parent, %{name: "Parent renamed"}, actor: admin)

      assert_has(session, "td", text: "Parent renamed", exact: true)
    end
  end

  describe "a list's bar" do
    test "stays down when a row only moved up behind a placeholder", ctx do
      %{conn: conn, admin: admin} = ctx

      first = product(name: "A first", actor: admin)
      product(name: "B second", actor: admin)
      third = product(name: "C third", actor: admin)

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products?limit=2")
        |> assert_has("td", text: first.name, exact: true)

      Ash.destroy!(first, actor: admin)
      session = assert_has(session, "tr[id='#{first.id}'][data-gone]")

      # The third row has moved up onto this page on a fresh read, but only
      # because the first left: an edit to it is no news.
      Ash.update!(third, %{name: "C third edited"}, action: :update, actor: admin)

      refute_has(session, "#list-news")
    end

    test "goes up for a create even where a row moved up", ctx do
      %{conn: conn, admin: admin} = ctx

      first = product(name: "A first", actor: admin)
      product(name: "B second", actor: admin)
      product(name: "D fourth", actor: admin)

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products?limit=2")

      Ash.destroy!(first, actor: admin)
      session = assert_has(session, "tr[id='#{first.id}'][data-gone]")

      product(name: "C third", actor: admin)

      assert_has(session, "#list-news")
    end

    test "stays down on a later page when a row before it left", ctx do
      %{conn: conn, admin: admin} = ctx

      first = product(name: "A first", actor: admin)
      product(name: "B second", actor: admin)
      third = product(name: "C third", actor: admin)

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products?limit=1&page=2")
        |> assert_has("td", text: "B second", exact: true)

      Ash.destroy!(first, actor: admin)
      Ash.update!(third, %{name: "C third edited"}, action: :update, actor: admin)

      session
      |> assert_has("td", text: "B second", exact: true)
      |> refute_has("#list-news")
    end

    test "goes up for a row edited back into the search", ctx do
      %{conn: conn, admin: admin} = ctx

      leaving = product(name: "Findable two", actor: admin)
      product(name: "Findable one", actor: admin)

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products?search=Findable")
        |> assert_has("td", text: leaving.name, exact: true)

      leaving = Ash.update!(leaving, %{name: "Renamed away"}, action: :update, actor: admin)
      session = assert_has(session, "tr[id='#{leaving.id}'][data-gone]")

      Ash.update!(leaving, %{name: "Findable back"}, action: :update, actor: admin)

      session
      |> assert_has("#list-news")
      |> click_button("#list-news button", "Reload")
      |> assert_has("td", text: "Findable back", exact: true)
    end

    test "stays down for a record its reader may not read", ctx do
      %{conn: conn, admin: admin} = ctx

      shown = Ash.create!(Example.Test.LiveRows, %{name: "Shown"}, authorize?: false)

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/test/live_rows")
        |> assert_has("td", text: shown.name, exact: true)

      Ash.create!(Example.Test.LiveRows, %{name: "A hidden one", hidden: true}, authorize?: false)

      refute_has(session, "#list-news")

      # The same page does hear a create it may read, so the refutal above is
      # about the policy rather than a deaf page.
      Ash.create!(Example.Test.LiveRows, %{name: "A visible one"}, authorize?: false)

      assert_has(session, "#list-news")
    end
  end

  describe "a list after its reader's own action" do
    # The reader asked for the change, so nothing moves behind their back: the
    # list closes up, and a queue they work through empties.
    test "closes up after a row delete", ctx do
      %{conn: conn, admin: admin} = ctx

      first = product(name: "A first", actor: admin)
      second = product(name: "B second", actor: admin)
      third = product(name: "C third", actor: admin)

      conn
      |> log_in(admin)
      |> visit(~p"/products?limit=2")
      |> force_row_action(first.id, :destroy)
      |> click_button("#{@modal} button", "Confirm")
      |> assert_has("#flash-info", text: "Record deleted successfully")
      |> refute_has("tr[id='#{first.id}']")
      |> assert_has("td", text: second.name, exact: true)
      |> assert_has("td", text: third.name, exact: true)
    end

    test "re-sorts after an update", ctx do
      %{conn: conn, admin: admin} = ctx

      first = product(name: "A first", actor: admin)
      second = product(name: "B second", actor: admin)

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> force_row_action(first.id, :update)
      |> fill_in("#{@modal} input", "Name", with: "Z first")
      |> click_button("#{@modal} button", "Save")
      |> assert_has("tbody tr:first-child td", text: second.name, exact: true)
      |> assert_has("tbody tr:nth-child(2) td", text: "Z first", exact: true)
    end

    test "closes up after a bulk delete", ctx do
      %{conn: conn, admin: admin} = ctx

      first = product(name: "A first", actor: admin)
      second = product(name: "B second", actor: admin)
      third = product(name: "C third", actor: admin)

      conn
      |> log_in(admin)
      |> visit(~p"/products?limit=2")
      |> tick_rows([first.id])
      |> click_link(@bulk, "Delete")
      |> click_button("#{@modal} button", "Confirm")
      |> refute_has("tr[id='#{first.id}']")
      |> assert_has("td", text: second.name, exact: true)
      |> assert_has("td", text: third.name, exact: true)
    end

    test "reads afresh when a modal is cancelled, dropping placeholders", ctx do
      %{conn: conn, admin: admin} = ctx

      first = product(name: "A first", actor: admin)
      product(name: "B second", actor: admin)
      third = product(name: "C third", actor: admin)

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products?limit=2")

      # Deleted elsewhere: a placeholder, until the reader's own next step.
      Ash.destroy!(first, actor: admin)
      session = assert_has(session, "tr[id='#{first.id}'][data-gone]")

      session
      |> click_button("Add Product")
      |> click_button("#{@modal} button", "Cancel")
      |> refute_has(@modal)
      |> refute_has("tr[id='#{first.id}']")
      |> assert_has("td", text: third.name, exact: true)
    end

    test "reads afresh when an update modal is cancelled, dropping placeholders", ctx do
      %{conn: conn, admin: admin} = ctx

      first = product(name: "A first", actor: admin)
      second = product(name: "B second", actor: admin)
      third = product(name: "C third", actor: admin)

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products?limit=2")

      Ash.destroy!(first, actor: admin)
      session = assert_has(session, "tr[id='#{first.id}'][data-gone]")

      session
      |> force_row_action(second.id, :update)
      |> click_button("#{@modal} button", "Cancel")
      |> refute_has(@modal)
      |> refute_has("tr[id='#{first.id}']")
      |> assert_has("td", text: second.name, exact: true)
      |> assert_has("td", text: third.name, exact: true)
    end

    # A notification inside `:refetch_window` is not dropped but deferred: the
    # list's `keep_live` sends itself `{:refetch, :data, ...}` for later. A form
    # runs no `keep_live` of its own and leaves the list's message hook in
    # place, so a refetch deferred before the visitor clicked New arrives on the
    # form. Sent by hand here, exactly as `Process.send_after/3` would.
    test "a refetch deferred before a form opened leaves the form alone", ctx do
      %{conn: conn, admin: admin} = ctx

      product = product(name: "Listed before New", actor: admin)

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/products?search=#{product.sku}")
      assert render(view) =~ product.name

      render_patch(view, ~p"/products/create")
      renamed = rename_behind_the_view(product)

      send(view.pid, {:refetch, :data, [requested_at: System.monotonic_time(:millisecond)]})

      html = render(view)
      assert Process.alive?(view.pid)
      assert html =~ "ash-quick-action-modal"

      # Nor does it re-read the list under the modal, which would also listen
      # again on the topics `Liveness.unsubscribe_all/2` let go of. Closing the
      # modal reads the list afresh. The list drawn behind the modal is a
      # snapshot, so the page's own `:data` is what shows whether it was read.
      %{ash_live_config: config, data: data} = :sys.get_state(view.pid).socket.assigns
      assert %{subscribed_topics: []} = config.data
      assert Enum.map(data.results, & &1.name) == [product.name]

      render_patch(view, ~p"/products?search=#{product.sku}")
      assert render(view) =~ renamed.name
    end
  end

  describe "a bulk action" do
    test "publishes for every row it wrote, so another page holding them follows", ctx do
      %{conn: conn, admin: admin} = ctx

      first = product(name: "First", actor: admin)
      second = product(name: "Second", actor: admin)

      # A second page on the same two rows, opened before the action. Nothing
      # on it is ever clicked, so anything it ends up showing arrived over a
      # topic.
      watching =
        conn
        |> log_in(admin)
        |> visit(~p"/products")
        |> assert_has("td", text: "First")

      first_topic = watch(first)
      second_topic = watch(second)

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> tick_rows([first.id, second.id])
      |> click_link(@bulk, "Deactivate")
      |> click_button("#{@modal} button", "Confirm")
      |> assert_has("tr[id='#{first.id}'].opacity-50")

      # One publication per row written, the same as a row action's — a bulk
      # write is a write, and a page holding the row has no way to tell which
      # menu it came from.
      assert_receive %Broadcast{topic: ^first_topic, payload: %Ash.Notifier.Notification{}}
      assert_receive %Broadcast{topic: ^second_topic, payload: %Ash.Notifier.Notification{}}

      watching
      |> assert_has("tr[id='#{first.id}'].opacity-50")
      |> assert_has("tr[id='#{second.id}'].opacity-50")
    end

    test "publishes for a destroy too", ctx do
      %{conn: conn, admin: admin} = ctx

      first = product(name: "First", actor: admin)
      second = product(name: "Second", actor: admin)

      first_topic = watch(first)
      second_topic = watch(second)

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> tick_rows([first.id, second.id])
      |> click_link(@bulk, "Delete")
      |> click_button("#{@modal} button", "Confirm")
      |> refute_has("td", text: "First")

      assert_receive %Broadcast{topic: ^first_topic, payload: %Ash.Notifier.Notification{}}
      assert_receive %Broadcast{topic: ^second_topic, payload: %Ash.Notifier.Notification{}}
    end

    # The failure below is `:reprice` refusing an inactive row rather than the
    # optimistic lock, and that is a finding rather than a convenience. A
    # selected row that moved behind the page does not fail a bulk update at
    # all — see the test after these two. A row the action itself refuses does,
    # and it fails the whole run: `transaction: :all` rolls back the rows that
    # went through before it.
    test "that fails writes nothing and tells nobody", ctx do
      %{conn: conn, admin: admin} = ctx

      first = product(name: "First", actor: admin)
      second = product(name: "Second", actor: admin) |> deactivated(admin)

      first_topic = watch(first)
      second_topic = watch(second)

      log =
        capture_log(fn ->
          conn
          |> log_in(admin)
          |> visit(~p"/products")
          |> tick_rows([first.id, second.id])
          |> reprice_selection("5.00")
          |> assert_has("#flash-error", text: "Only an active product can be repriced.")
        end)

      # `:reprice` writes a `PriceChange` beside the product, so "nothing was
      # written" covers the action's own trail and not just the column.
      assert Money.to_string!(Ash.reload!(first, authorize?: false).price) =~ "10"
      assert Money.to_string!(Ash.reload!(second, authorize?: false).price) =~ "10"
      assert PriceChange |> Ash.read!(authorize?: false) == []

      # And nothing was announced about either row. A notification for a write
      # that did not happen is worse than none: every page holding the row
      # re-reads it to find it unchanged.
      refute_receive %Broadcast{topic: ^first_topic}
      refute_receive %Broadcast{topic: ^second_topic}

      refute log =~ "Missed"
    end

    test "that fails leaves nothing queued for the next action to send", ctx do
      %{conn: conn, admin: admin} = ctx

      first = product(name: "First", actor: admin)
      second = product(name: "Second", actor: admin) |> deactivated(admin)
      unrelated = product(name: "Unrelated", actor: admin)

      first_topic = watch(first)
      second_topic = watch(second)
      unrelated_topic = watch(unrelated)

      log =
        capture_log(fn ->
          conn
          |> log_in(admin)
          |> visit(~p"/products")
          |> tick_rows([first.id, second.id])
          |> reprice_selection("5.00")
          |> assert_has("#flash-error", text: "Only an active product can be repriced.")
          # A notification held back rather than dropped sits in the LiveView's
          # own state, and the next thing that process sends carries it out. So
          # the page goes on to do something that does publish.
          |> force_row_action(unrelated.id, :deactivate)
          |> click_button("#ash-quick-action-modal button", "Confirm")
        end)

      assert_receive %Broadcast{topic: ^unrelated_topic, payload: %Ash.Notifier.Notification{}}

      refute_receive %Broadcast{topic: ^first_topic}
      refute_receive %Broadcast{topic: ^second_topic}

      refute log =~ "Missed"

      refute Ash.reload!(unrelated, authorize?: false).active
    end

    # `Product` is versioned, so the moved row no longer matches the lock and the
    # bulk write skips it without an error. The page says so and keeps that row
    # selected; the row that was written still publishes, the skipped one stays
    # quiet.
    test "over a row that moved behind the page skips it rather than failing", ctx do
      %{conn: conn, admin: admin} = ctx

      first = product(name: "First", actor: admin)
      second = product(name: "Second", actor: admin)

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products")
        |> tick_rows([first.id, second.id])

      move_behind_the_view(second)

      first_topic = watch(first)
      second_topic = watch(second)

      session
      |> click_link(@bulk, "Deactivate")
      |> click_button("#{@modal} button", "Confirm")
      |> assert_has("#flash-error",
        text:
          "Deactivate applied to 1 of 2 selected rows. The other row was not changed " <>
            "and is still selected: check it and try again."
      )
      |> assert_has("input[name='#{second.id}'][checked]")
      |> refute_has("input[name='#{first.id}'][checked]")

      refute Ash.reload!(first, authorize?: false).active
      assert Ash.reload!(second, authorize?: false).active

      assert_receive %Broadcast{topic: ^first_topic, payload: %Ash.Notifier.Notification{}}
      refute_receive %Broadcast{topic: ^second_topic}
    end
  end

  describe "a details page" do
    test "refetches for its own record and ignores another", %{conn: conn, admin: admin} do
      shown = product(name: "The one open", actor: admin)
      other = product(name: "Some other", actor: admin)

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products/#{shown.id}")
        |> assert_has("h1", text: "The one open")

      renamed = rename_behind_the_view(shown)

      Ash.update!(other, action: :deactivate, actor: admin)

      session
      |> refute_has("h1", text: renamed.name)
      |> assert_has("h1", text: "The one open")

      Ash.update!(shown, action: :deactivate, actor: admin)

      session
      |> assert_has("h1", text: renamed.name)
      |> assert_has(~s([data-field="active"] dd), text: "No", exact: true)
    end

    test "drops the topics the list was holding when a record is opened", ctx do
      %{conn: conn, admin: admin} = ctx

      opened = product(name: "Opened", actor: admin)
      sibling = product(name: "Sibling", actor: admin)

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products")
        |> assert_has("td", text: sibling.name)
        # Navigating to the details page re-scopes: the list's per-row
        # subscriptions go with the assign they were derived from.
        |> visit(~p"/products/#{opened.id}")
        |> assert_has("h1", text: "Opened")

      renamed_sibling = rename_behind_the_view(sibling)
      Ash.update!(sibling, action: :deactivate, actor: admin)

      # A refetch here would be the details page re-reading its own record, and
      # the sibling is not on it either way. Back on the list, it is.
      session
      |> refute_has("*", text: renamed_sibling.name)
      |> visit(~p"/products")
      |> assert_has("td", text: renamed_sibling.name)
    end
  end

  describe "a not-found page reached from the list" do
    # A patch to a URL the page cannot serve leaves the list's hooks behind
    # unless something takes them off. A refetch the list had already scheduled
    # then read through a nil action and took the view down, and the list's
    # events still acted on a selection the page no longer shows.
    test "drops the list's refetch, events and selection", %{conn: conn, admin: admin} do
      product = product(name: "Four-season tent", actor: admin)

      {:ok, view, _html} = conn |> log_in(admin) |> live(~p"/products")
      render_change(view, "table-form-change", %{product.id => "on"})

      render_patch(view, ~p"/products?action=read")
      assert has_element?(view, "h1", "404")

      # The refetch a coalesced notification schedules, landing after the patch.
      send(view.pid, {:refetch, :data, []})
      render_click(view, "bulk_action", %{"action_name" => "destroy"})

      assert Process.alive?(view.pid)
      assert has_element?(view, "h1", "404")
      assert :sys.get_state(view.pid).socket.assigns.selected_rows == %{}
    end
  end

  describe "a resource that publishes nothing" do
    test "leaves its pages inert, however much is written to it", %{conn: conn, admin: admin} do
      # `Example.Accounts.AuditLog` declares `liveness enabled? false`: every
      # write in the app appends to it, so a live list would offer its readers
      # "new records" all the time.
      refute AshQuick.Topics.enabled?(AuditLog)
      refute AshQuick.Topics.enabled?(PriceChange)
      assert AshQuick.Topics.enabled?(Product)

      product = product(name: "Writes a trail", actor: admin)

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/audit_logs")
        |> assert_has("td", text: "Create")

      # A write that lands several audit rows. The page is holding the ones that
      # were there when it rendered, and hears about none of this.
      reprice(product, to: Money.new(:USD, "149.00"), actor: admin)

      refute_has(session, "td", text: "Reprice")

      # And they are really in the table — the refutal is about the page not
      # being told, not about the write not happening.
      conn
      |> log_in(admin)
      |> visit(~p"/audit_logs")
      |> assert_has("td", text: "Reprice")
    end
  end

  describe "the two sides of a topic" do
    test "are derived from the same place, so they cannot disagree" do
      # The publishing half is `AshQuick.PubSub.Transformer`, which writes the
      # resource's `pub_sub` prefix; the listening half is
      # `AshQuick.LiveView.Liveness`. Both read `AshQuick.Topics`, and a prefix
      # spelled out on either side could drift from the other with no symptom —
      # the page would simply never update.
      for resource <- [Product, Brand] do
        assert AshQuick.Topics.enabled?(resource)

        assert Spark.Dsl.Extension.get_opt(resource, [:pub_sub], :prefix) ==
                 AshQuick.Topics.collection(resource)
      end
    end

    test "and no two publishing resources share one" do
      # A shared prefix would make two resources' records indistinguishable on
      # the wire: a page holding `brand:<uuid>` would wake for a product that
      # happened to have the same id.
      publishing =
        for domain <- Application.fetch_env!(:example, :ash_domains),
            resource <- Ash.Domain.Info.resources(domain),
            AshQuick.Topics.enabled?(resource) do
          {AshQuick.Topics.collection(resource), resource}
        end

      assert publishing != []

      by_topic = Enum.group_by(publishing, &elem(&1, 0), &elem(&1, 1))
      shared = for {topic, [_, _ | _] = resources} <- by_topic, do: {topic, resources}

      assert shared == []
    end
  end

  # Bumps the version column and tells nobody, which leaves the row the page is
  # holding a copy the optimistic lock no longer matches.
  #
  # A real `Ash.update!` would move the row too, but not past this page: the
  # file zeroes `:refetch_window`, so the notification that write publishes
  # reaches the page before the next click does and the page refetches itself
  # back into step. `Ash.Seed` runs no action, so it fires no notification — the
  # same reason `rename_behind_the_view/1` uses it.
  defp move_behind_the_view(record) do
    Ash.Seed.update!(record, %{version: record.version + 1})
  end

  # Subscribes the test process to one record's topic — the same topic a page
  # holding that row listens on, derived through `AshQuick.Topics` rather than
  # spelled out, for the reason that module exists.
  defp watch(%resource{id: id}) do
    topic = AshQuick.Topics.record(resource, id)
    :ok = ExampleWeb.Endpoint.subscribe(topic)
    topic
  end

  # Writes the column and tells nobody. Ash's notifications come from the
  # action, and `Ash.Seed` runs none — so the new name sits in the table,
  # invisible to the page, until something else makes it refetch.
  defp rename_behind_the_view(record) do
    Ash.Seed.update!(record, %{name: "Renamed behind the view #{unique("")}"})
  end

  defp deactivated(product, actor),
    do: Ash.update!(product, %{}, action: :deactivate, actor: actor)

  # Opens `:reprice` over the selection and saves `price` for every row.
  defp reprice_selection(session, price) do
    session
    |> click_link(@bulk, "Reprice")
    |> fill_in("#{@modal} input", "Price", with: price)
    |> click_button("#{@modal} button", "Save")
  end
end
