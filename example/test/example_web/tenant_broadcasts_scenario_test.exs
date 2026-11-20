defmodule ExampleWeb.TenantBroadcastsScenarioTest do
  @moduledoc """
  A write is announced inside its tenant, and the announcement names a record
  without carrying it.

  Every subscriber on a topic receives the same message, so a topic shared by
  two tenants hands each one's writes to the other's open pages, and a payload
  carrying the record hands over its data with them: the reader's own read
  afterwards would never have shown it. Both halves are asserted here, on the
  wire and in the mailbox of a page that is open.

  `Example.Catalog.Product` is `global?` over an attribute tenant;
  `Example.Test.TenantBroadcasts` holds an attribute resource that is not
  `global?` and a context one. Each tenant here is fresh, so no other test
  publishes on its topics.
  """
  use ExampleWeb.FeatureCase, async: true

  alias AshQuick.PubSub.Notice
  alias AshQuick.Topics
  alias Example.Catalog.Product
  alias AshQuick.LiveView.Liveness
  alias AshQuick.LiveView.QuickView.Options
  alias Example.Test.TenantBroadcasts.{Bin, Crate, Locker}
  alias Phoenix.Socket.Broadcast

  describe "an attribute tenant without global?" do
    test "announces a write to its own tenant's topics only", %{admin: admin} do
      north = Ash.UUID.generate()
      south = Ash.UUID.generate()

      north_topic = subscribe(Topics.collection(Crate, north))
      south_topic = subscribe(Topics.collection(Crate, south))
      bare_topic = subscribe(Topics.collection(Crate, nil))

      crate = Ash.create!(Crate, %{name: "North crate"}, tenant: north, actor: admin)
      record_topic = Topics.record(Crate, crate.id, north)

      assert north_topic == "crate:tenant:#{north}"
      assert record_topic == "crate:tenant:#{north}:#{crate.id}"

      assert_receive %Broadcast{topic: ^north_topic, payload: payload}
      assert payload == %Notice{resource: Crate, id: crate.id, type: :create}

      # A reader with no tenant cannot read a crate, so nothing is published
      # where one would listen.
      refute_receive %Broadcast{topic: ^south_topic}
      refute_receive %Broadcast{topic: ^bare_topic}
    end

    test "announces an update and a destroy the same way", %{admin: admin} do
      north = Ash.UUID.generate()
      crate = Ash.create!(Crate, %{name: "North crate"}, tenant: north, actor: admin)
      topic = subscribe(Topics.record(Crate, crate.id, north))

      crate = Ash.update!(crate, %{name: "Renamed crate"}, tenant: north, actor: admin)
      assert_receive %Broadcast{topic: ^topic, payload: %Notice{type: :update} = updated}

      Ash.destroy!(crate, tenant: north, actor: admin)
      assert_receive %Broadcast{topic: ^topic, payload: %Notice{type: :destroy} = destroyed}

      for notice <- [updated, destroyed] do
        assert notice == %Notice{resource: Crate, id: crate.id, type: notice.type}
      end
    end
  end

  describe "a context tenant" do
    test "announces a write to its own tenant's topics only", %{admin: admin} do
      north = Ash.UUID.generate()
      south = Ash.UUID.generate()

      north_topic = subscribe(Topics.collection(Locker, north))
      south_topic = subscribe(Topics.collection(Locker, south))
      bare_topic = subscribe(Topics.collection(Locker, nil))

      locker = Ash.create!(Locker, %{name: "North locker"}, tenant: north, actor: admin)

      assert north_topic == "locker:tenant:#{north}"
      assert_receive %Broadcast{topic: ^north_topic, payload: payload}
      assert payload == %Notice{resource: Locker, id: locker.id, type: :create}

      refute_receive %Broadcast{topic: ^south_topic}
      refute_receive %Broadcast{topic: ^bare_topic}
    end
  end

  describe "a resource with read actions that cross tenants" do
    test "also announces every write on the bare topics", %{admin: admin} do
      north = Ash.UUID.generate()
      north_topic = subscribe(Topics.collection(Bin, north))
      bare_topic = subscribe(Topics.collection(Bin, nil))

      bin = Ash.create!(Bin, %{name: "North bin"}, tenant: north, actor: admin)
      id = bin.id

      assert_receive %Broadcast{topic: ^north_topic, payload: %Notice{id: ^id}}
      assert_receive %Broadcast{topic: ^bare_topic, payload: %Notice{id: ^id}}
    end

    test "is listened to on the bare topics by a page that reads across them" do
      north = Ash.UUID.generate()
      options = %Options{module: nil, domain: nil, resource: Bin, liveness_options: []}
      action = &Ash.Resource.Info.action(Bin, &1)

      # A reader in a store, through `:bypass`, sees every store's bins; one
      # with no store, through `:allow_global`, sees them too; through the
      # primary read, a reader in a store sees only its own.
      assert list_topics(options, north, action.(:across)) == [Topics.collection(Bin, nil)]
      assert list_topics(options, nil, action.(:anywhere)) == [Topics.collection(Bin, nil)]
      assert list_topics(options, north, action.(:read)) == ["bin:tenant:#{north}"]
    end
  end

  describe "a tenant containing the delimiter" do
    test "names no topic, and its writes reach no other tenant's", %{admin: admin} do
      north = Ash.UUID.generate()
      locker = Ash.create!(Locker, %{name: "North locker"}, tenant: north, actor: admin)
      record_topic = subscribe(Topics.record(Locker, locker.id, north))

      # This tenant's collection topic would spell out north's record topic.
      lookalike = "#{north}:#{locker.id}"
      assert Topics.collection(Locker, lookalike) == nil
      assert Topics.record(Locker, locker.id, lookalike) == nil

      options = %Options{module: nil, domain: nil, resource: Locker, liveness_options: []}
      assert list_topics(options, lookalike, nil) == []

      Ash.create!(Locker, %{name: "Lookalike locker"}, tenant: lookalike, actor: admin)
      refute_receive %Broadcast{topic: ^record_topic}

      Ash.update!(locker, %{name: "Renamed locker"}, tenant: north, actor: admin)
      assert_receive %Broadcast{topic: ^record_topic, payload: %Notice{type: :update}}
    end
  end

  describe "a global? attribute tenant" do
    setup %{admin: admin} do
      %{
        north: store(name: "Northwind", actor: admin),
        south: store(name: "Southgate", actor: admin)
      }
    end

    test "announces a write to its record's tenant, even one made without a tenant", ctx do
      %{admin: admin, north: north, south: south} = ctx

      north_topic = subscribe(Topics.collection(Product, north.id))
      south_topic = subscribe(Topics.collection(Product, south.id))

      # Platform staff write with no tenant; the store is the record's own.
      product = product(name: "North tent", store: north, actor: admin)
      id = product.id

      assert_receive %Broadcast{topic: ^north_topic, payload: %Notice{id: ^id, type: :create}}
      refute_receive %Broadcast{topic: ^south_topic}
    end

    test "also announces every write on the bare topics, for readers with no tenant", ctx do
      %{admin: admin, north: north} = ctx

      record = product(name: "North tent", store: north, actor: admin)
      topic = subscribe(Topics.record(Product, record.id, nil))

      Ash.update!(record, %{name: "North tent, renamed"}, actor: admin, authorize?: false)

      assert_receive %Broadcast{topic: ^topic, payload: %Notice{type: :update} = notice}
      assert notice == %Notice{resource: Product, id: record.id, type: :update}
    end

    # Known gap: the tenant segment is the attribute as written, since reading
    # it as it was needs the original row, which a fully atomic update does not
    # read. A page in the store a record left holds it and is not told.
    @tag :skip
    test "announces a record moved to another store in the store it left", ctx do
      %{admin: admin, north: north, south: south} = ctx

      record = product(name: "Moving tent", store: north, actor: admin)
      topic = subscribe(Topics.record(Product, record.id, north.id))

      record
      |> Ash.Changeset.for_update(:update, %{}, actor: admin, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:store_id, south.id)
      |> Ash.update!(authorize?: false)

      assert_receive %Broadcast{topic: ^topic, payload: %Notice{type: :update}}
    end

    test "is followed by a page inside a store, and nothing from another store reaches it",
         ctx do
      %{conn: conn, admin: admin, north: north, south: south} = ctx

      keeper = user(:editor, name: "Nora North", store: north, actor: admin)
      shown = product(name: "North tent", store: north, actor: admin)

      {:ok, view, _html} = conn |> log_in(keeper) |> live(~p"/products")
      assert render(view) =~ shown.name

      # The list listens inside its reader's store, never on the bare topic
      # every store's writes go out on.
      topics = :sys.get_state(view.pid).socket.assigns.ash_live_config.data.subscribed_topics
      assert Topics.collection(Product, north.id) in topics
      refute Topics.collection(Product, nil) in topics
      refute Topics.collection(Product, south.id) in topics

      :erlang.trace(view.pid, true, [:receive])

      south_id = product(name: "South tent", store: south, actor: admin).id
      north_product = product(name: "Second north tent", store: north, actor: admin)
      north_id = north_product.id

      # The north write arrives, as a notice and nothing more; the south one
      # never does, so no mailbox on this page ever held its data.
      assert_receive {:trace, _pid, :receive,
                      %Broadcast{payload: %Notice{id: ^north_id, type: :create}}}

      # `render/1` is a call into the page, answered after every message
      # already in its mailbox, so whatever the writes sent has arrived.
      render(view)
      :erlang.trace(view.pid, false, [:receive])

      refute_received {:trace, _pid, :receive, %Broadcast{payload: %Notice{id: ^south_id}}}

      refute_received {:trace, _pid, :receive, %Broadcast{payload: %Ash.Notifier.Notification{}}}
    end
  end

  defp list_topics(options, tenant, action) do
    options
    |> Liveness.list_options(tenant, action)
    |> Keyword.fetch!(:subscribe)
    |> then(& &1.([]))
  end

  defp subscribe(topic) do
    :ok = ExampleWeb.Endpoint.subscribe(topic)
    topic
  end
end
