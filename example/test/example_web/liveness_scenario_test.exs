defmodule ExampleWeb.LivenessScenarioTest do
  @moduledoc """
  A QuickView refetches for the records it is showing, not for the resource.

  Ash publishes both `"product:<id>"` and the bare `"product"` for every write.
  A page listens on the per-record topics it derives from the rows it is
  actually holding, so a change to anything else never reaches it — which is the
  difference between a list that stays current and one that re-reads the table
  every time anybody anywhere saves something.

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
  alias Example.Catalog.{Brand, PriceChange, Product}
  alias Phoenix.Socket.Broadcast

  # The bulk menu shares its labels with the row menu, so a bulk action is
  # addressed by the event it pushes rather than by its text.
  @bulk "a[phx-click*='bulk_action']"

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

      # A real write to a record this page is not holding. It publishes, and the
      # page is not listening.
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

    test "is live on its rows and not on the collection, so a new record waits", ctx do
      %{conn: conn, admin: admin} = ctx

      shown = product(name: "Already listed", actor: admin)

      session =
        conn
        |> log_in(admin)
        |> visit(~p"/products")
        |> assert_has("td", text: shown.name)

      later = product(name: "Created afterwards", actor: admin)

      # A page subscribes to the records it is holding, one topic each. Nothing
      # could have subscribed to a row that did not exist when it rendered, and
      # the bare `"product"` topic — which is published — is deliberately not
      # listened to: a page that refetched for every create in the table would
      # be re-reading it on every write anybody makes.
      #
      # This is the same fact `Example.Accounts.AuditLog` cites for turning
      # liveness off outright: a refetch refreshes rows already on screen, so an
      # append-only resource could never surface a new one anyway.
      session
      |> refute_has("td", text: later.name)
      |> assert_has("td", text: shown.name)

      # It is there for the next reader, so the refutal is about what this page
      # was told rather than about the create not landing.
      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> assert_has("td", text: later.name)
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
      |> refute_has("td", text: "First")

      assert_receive %Broadcast{topic: ^first_topic, payload: %Ash.Notifier.Notification{}}
      assert_receive %Broadcast{topic: ^second_topic, payload: %Ash.Notifier.Notification{}}
    end

    # The failure below is a forged `:reprice` rather than the optimistic lock,
    # and that is a finding rather than a convenience. A selected row that moved
    # behind the page does not fail a bulk update at all — see the test after
    # these two. So the only way to watch this clause *fail* is an action that
    # cannot be built: `:reprice` needs a price, and the bulk endpoint takes
    # `%{}`. It fails before any row is written, which is the shape every
    # failure of a derived bulk action has here — a derived action is input-less
    # and its policy is actor-wide, so nothing refuses row two after row one
    # went through.
    test "that fails writes nothing and tells nobody", ctx do
      %{conn: conn, admin: admin} = ctx

      first = product(name: "First", actor: admin)
      second = product(name: "Second", actor: admin)

      first_topic = watch(first)
      second_topic = watch(second)

      log =
        capture_log(fn ->
          conn
          |> log_in(admin)
          |> visit(~p"/products")
          |> tick_rows([first.id, second.id])
          |> force_bulk_action(:reprice)
          # "Unknown Error" is what this clause's existing error handling puts
          # in the flash — `run_bulk_action/3` passes no `return_errors?`, so
          # the result carries no errors to describe. Untouched here; the
          # assertion is that an error flash is shown at all.
          |> assert_has("#flash-error", text: "Unknown Error")
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
      second = product(name: "Second", actor: admin)
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
          |> force_bulk_action(:reprice)
          |> assert_has("#flash-error", text: "Unknown Error")
          # A notification held back rather than dropped sits in the LiveView's
          # own state, and the next thing that process sends carries it out. So
          # the page goes on to do something that does publish.
          |> force_row_action(unrelated.id, :deactivate)
        end)

      assert_receive %Broadcast{topic: ^unrelated_topic, payload: %Ash.Notifier.Notification{}}

      refute_receive %Broadcast{topic: ^first_topic}
      refute_receive %Broadcast{topic: ^second_topic}

      refute log =~ "Missed"

      refute Ash.reload!(unrelated, authorize?: false).active
    end

    # Recording what `transaction: :all` does and does not cover, because the
    # obvious way to fail a bulk Deactivate turns out not to fail it.
    #
    # `Product` is versioned, so a selected row moved behind the page is one the
    # optimistic lock's filter no longer matches. A single-row update raises
    # `StaleRecord` on that; a bulk update writes zero rows and calls it a
    # success, so the batch comes back `:success`, the other row is committed,
    # and the moved row is silently left alone. Nothing rolls back because
    # nothing errored.
    #
    # This is not what this test file is about and not what the notification
    # change alters — it is here so the next reader does not spend the afternoon
    # I did looking for the failure. What liveness has to get right either way
    # is the last assertion: the row that was written publishes, and the row
    # that was not stays quiet.
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
      |> refute_has("#flash-error")

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
      |> assert_has("dd", text: "False")
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

  describe "a resource that publishes nothing" do
    test "leaves its pages inert, however much is written to it", %{conn: conn, admin: admin} do
      # `Example.Accounts.AuditLog` declares `liveness enabled? false` — it is
      # append-only, and a refetch only refreshes rows already on screen, so a
      # new entry could never appear and publishing would be traffic nothing can
      # act on.
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
end
