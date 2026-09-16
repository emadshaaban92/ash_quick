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

  alias Example.Accounts.AuditLog
  alias Example.Catalog.{Brand, PriceChange, Product}

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

  # Writes the column and tells nobody. Ash's notifications come from the
  # action, and `Ash.Seed` runs none — so the new name sits in the table,
  # invisible to the page, until something else makes it refetch.
  defp rename_behind_the_view(record) do
    Ash.Seed.update!(record, %{name: "Renamed behind the view #{unique("")}"})
  end
end
