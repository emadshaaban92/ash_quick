defmodule ExampleWeb.QuietWritesScenarioTest do
  @moduledoc """
  A quiet update that changes nothing publishes nothing on the topics
  AshQuick adds, so no page open on the record refetches for it. Every other
  update publishes, since a hook may have changed what a page shows through
  records the page does not listen on.

  "Changes nothing" is the one answer `AshQuick.Bookkeeping.Meaningful` gives
  the lock and the stamps too, so a quiet write that leaves `version`,
  `updated_by` and `updated_at` alone also leaves every page alone: printing a
  record, or downloading a file from it, is not a change any page has to read
  again.

  The resource is `Example.Test.QuietWrites`, with auditing, bookkeeping and
  versioning all on, at `/test/quiet_writes`.

  A page's refetch is probed the way `ExampleWeb.LivenessScenarioTest` probes
  it: an `Ash.Seed.update!` rename writes the row without a notification, so
  the new name shows only once something else makes the page read again. Each
  `refute` is followed by an `assert` on the same page, since a page that is
  simply broken passes every `refute`.

  `async: false`: `:refetch_window` is application env, and zeroing it is a
  global swap.
  """
  use ExampleWeb.ConnCase, async: false

  alias Example.Test.Downloadable.Watermark
  alias Example.Test.QuietWrites
  alias Phoenix.Socket.Broadcast

  @page "/test/quiet_writes"
  @modal "#ash-quick-action-modal"

  setup do
    previous = Application.fetch_env(:ash_quick, :refetch_window)
    Application.put_env(:ash_quick, :refetch_window, 0)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_quick, :refetch_window, value)
        :error -> Application.delete_env(:ash_quick, :refetch_window)
      end
    end)
  end

  describe "a quiet update" do
    test "that changes nothing publishes nothing on either topic", %{admin: admin} do
      record = quiet_write(admin)
      listen(record)

      returned = Ash.update!(record, %{}, action: :watermark, actor: admin)

      refute_broadcast(record)

      # Nor anything that the broadcast would have announced.
      assert returned.version == record.version
      assert returned.updated_by_id == record.updated_by_id
      assert returned.updated_at == record.updated_at
    end

    test "that changes nothing leaves a page open on the record", %{conn: conn, admin: admin} do
      record = quiet_write(admin)
      {:ok, view, _html} = conn |> log_in(admin) |> live("#{@page}/#{record.id}")

      renamed = rename_behind_the_view(record)
      Ash.update!(record, %{}, action: :watermark, actor: admin)

      refute render(view) =~ renamed.name

      # A write that does change something, on the same page.
      Ash.update!(record, %{note: "changed"}, action: :update, actor: admin)

      assert render(view) =~ renamed.name
    end

    test "publishes when the same action changes an attribute", %{admin: admin} do
      record = quiet_write(admin)
      listen(record)

      Ash.update!(record, %{note: "first"}, action: :update, actor: admin)

      assert_broadcast(record)

      # The same action, the same value again: nothing to publish.
      Ash.update!(Ash.reload!(record, authorize?: false), %{note: "first"},
        action: :update,
        actor: admin
      )

      refute_broadcast(record)
    end

    test "resubmitted unchanged from its form publishes nothing", %{conn: conn, admin: admin} do
      record = quiet_write(admin, note: "kept")
      {:ok, view, _html} = conn |> log_in(admin) |> live("#{@page}/#{record.id}/update")
      listen(record)

      view
      |> form("form[id='#{record.id}-form']", %{
        "form" => %{"name" => record.name, "note" => "kept"}
      })
      |> render_submit()

      assert render(view) =~ "Record saved successfully"
      refute_broadcast(record)

      assert Ash.reload!(record, authorize?: false).version == record.version
    end

    # On the atomic path Ash writes every accepted input, unchanged ones
    # included, and only the data layer compares them with the row. The
    # notification is built from the changeset, which cannot say whether the
    # value differed, so it publishes: a broadcast too many is a wasted
    # refetch, and one missed is a page showing stale data with no symptom.
    # The version, which the data layer did compare, stays where it was.
    test "on the atomic path, with values equal to the row's, still publishes", %{admin: admin} do
      record = quiet_write(admin)
      listen(record)

      returned = Ash.update!(record, %{name: record.name}, action: :rename_atomic, actor: admin)

      assert_broadcast(record)
      assert returned.version == record.version
    end

    # With nothing accepted there is no atomic to compare, so the atomic path
    # knows as well as memory does that nothing changed.
    test "on the atomic path, accepting nothing, publishes nothing", %{admin: admin} do
      record = quiet_write(admin)
      listen(record)

      Ash.update!(record, %{}, action: :stamp_atomic, actor: admin)

      refute_broadcast(record)
    end

    test "that changes only a relationship still publishes", %{admin: admin} do
      record = quiet_write(admin)
      listen(record)

      Ash.update!(record, %{notes: [%{body: "added"}]}, action: :add_notes, actor: admin)

      assert_broadcast(record)
      assert Ash.load!(record, :note_count, authorize?: false).note_count == 1
    end

    test "still fires a publication the resource declares itself", %{admin: admin} do
      record = quiet_write(admin)
      own = "#{AshQuick.Topics.collection(QuietWrites)}:pinged:#{record.id}"
      listen(record)
      ExampleWeb.Endpoint.subscribe(own)

      Ash.update!(record, %{}, action: :ping, actor: admin)

      assert_receive %Broadcast{topic: ^own, payload: %Ash.Notifier.Notification{}}
      refute_broadcast(record)
    end

    test "publishes nothing for a listed print", %{admin: admin} do
      record = quiet_write(admin)
      listen(record)

      Ash.update!(record, %{}, action: :print, actor: admin)

      refute_broadcast(record)
    end
  end

  describe "an update that is not quiet" do
    # `:tally` writes nothing of its own record, but adds a note to it, which
    # the page counts. The note's own publication does not reach a page on
    # the record, so only the record's own broadcast refreshes it.
    test "publishes though it changes nothing of its record", ctx do
      %{conn: conn, admin: admin} = ctx
      record = quiet_write(admin)
      {:ok, view, _html} = conn |> log_in(admin) |> live("#{@page}/#{record.id}")
      listen(record)

      returned = Ash.update!(record, %{}, action: :tally, actor: admin)

      assert_broadcast(record)
      assert returned.version == record.version
      assert view |> element("[data-field='note_count']") |> render() =~ "1"
    end

    # A print is quiet only when the resource lists it: one that also numbers
    # or records itself in a hook changes what a page shows.
    test "publishes for a print the resource did not list", %{admin: admin} do
      record = quiet_write(admin)
      listen(record)

      Ash.update!(record, %{}, action: :print_unlisted, actor: admin)

      assert_broadcast(record)
    end
  end

  describe "a bulk update" do
    test "publishes for the records it changed and not for the others", %{admin: admin} do
      changed = quiet_write(admin, note: "before")
      unchanged = quiet_write(admin, note: "after")
      listen(changed)
      listen(unchanged)

      Ash.bulk_update!([changed, unchanged], :update, %{note: "after"},
        strategy: :stream,
        notify?: true,
        actor: admin
      )

      changed_topic = AshQuick.Topics.record(QuietWrites, changed.id)
      unchanged_topic = AshQuick.Topics.record(QuietWrites, unchanged.id)

      assert_receive %Broadcast{topic: ^changed_topic}
      refute_receive %Broadcast{topic: ^unchanged_topic}
    end
  end

  describe "a file from an update that changes nothing" do
    test "reaches the tab that asked, and no other tab refetches", %{conn: conn, admin: admin} do
      record = quiet_write(admin)
      conn = log_in(conn, admin)

      {:ok, asking, _html} = live(conn, "#{@page}/#{record.id}")
      {:ok, watching, _html} = live(conn, "#{@page}/#{record.id}")

      renamed = rename_behind_the_view(record)

      asking
      |> element("#details-more-actions-dropdown a", ~r/^\s*Print\s*$/)
      |> render_click()

      confirm(asking)

      assert_push_event(asking, "ash_quick:pdf", %{delivery: :download})
      assert render(asking) =~ "successfully"
      refute render(watching) =~ renamed.name

      asking
      |> element("#details-more-actions-dropdown a", ~r/^\s*Watermark\s*$/)
      |> render_click()

      confirm(asking)

      assert_push_event(asking, "ash_quick:download", event)
      assert event.data == Base.encode64(Watermark.bytes(renamed))

      # The tab that ran them reads afresh on its own, without its broadcast.
      assert render(asking) =~ renamed.name
      refute render(watching) =~ renamed.name

      Ash.update!(record, %{note: "changed"}, action: :update, actor: admin)

      assert render(watching) =~ renamed.name
    end
  end

  defp quiet_write(actor, attrs \\ []) do
    QuietWrites
    |> Ash.Changeset.for_create(
      :create,
      %{
        code: unique("Q"),
        name: unique("Quiet "),
        note: Keyword.get(attrs, :note)
      },
      actor: actor
    )
    |> Ash.create!()
  end

  defp listen(record) do
    ExampleWeb.Endpoint.subscribe(AshQuick.Topics.record(QuietWrites, record.id))
    ExampleWeb.Endpoint.subscribe(AshQuick.Topics.collection(QuietWrites))
  end

  defp assert_broadcast(record) do
    record_topic = AshQuick.Topics.record(QuietWrites, record.id)
    collection_topic = AshQuick.Topics.collection(QuietWrites)

    assert_receive %Broadcast{topic: ^record_topic, payload: %Ash.Notifier.Notification{}}
    assert_receive %Broadcast{topic: ^collection_topic, payload: %Ash.Notifier.Notification{}}
  end

  defp refute_broadcast(record) do
    record_topic = AshQuick.Topics.record(QuietWrites, record.id)
    collection_topic = AshQuick.Topics.collection(QuietWrites)

    refute_receive %Broadcast{topic: ^record_topic}
    refute_receive %Broadcast{topic: ^collection_topic}
  end

  # Written without a notification, so only a refetch shows it.
  defp rename_behind_the_view(record) do
    Ash.Seed.update!(record, %{name: unique("Renamed ")})
  end

  defp confirm(view) do
    view |> form("#{@modal} form") |> render_submit()
  end
end
