defmodule AshQuick.OwnPubSubTest do
  @moduledoc """
  A resource with `extensions: [AshQuick]` can write its own `pub_sub` block,
  and one that also lists `notifiers: [Ash.Notifier.PubSub]` behaves the same.

  `AshQuick` brings `Ash.Notifier.PubSub`'s DSL in through `add_extensions`, and
  registers the notifier itself unless the resource already did. Either way the
  notifier runs once per write: a second registration would broadcast every
  topic twice.
  """
  use ExUnit.Case, async: true

  alias Example.Test.OwnPubSub.{AlsoNotifier, ExtensionOnly}
  alias Phoenix.Socket.Broadcast

  for resource <- [ExtensionOnly, AlsoNotifier] do
    describe inspect(resource) do
      test "registers the notifier once" do
        assert Ash.Resource.Info.notifiers(unquote(resource)) == [Ash.Notifier.PubSub]
      end

      test "keeps its own publication next to AshQuick's" do
        topics =
          unquote(resource)
          |> Ash.Notifier.PubSub.Info.publications()
          |> Enum.map(&{&1.action || &1.type, &1.topic})

        assert topics == [
                 {:create, ["made", :id]},
                 {:create, [[:id, nil]]},
                 {:update, [[:id, nil]]},
                 {:destroy, [[:id, nil]]}
               ]
      end

      test "broadcasts each topic once per write" do
        resource = unquote(resource)
        prefix = AshQuick.Topics.collection(resource)
        id = Ash.UUID.generate()

        for topic <- ["#{prefix}:made:#{id}", "#{prefix}:#{id}", prefix] do
          ExampleWeb.Endpoint.subscribe(topic)
        end

        resource
        |> Ash.Changeset.for_create(:create, %{name: "Made"})
        |> Ash.Changeset.force_change_attribute(:id, id)
        |> Ash.create!(authorize?: false)

        for topic <- ["#{prefix}:made:#{id}", "#{prefix}:#{id}", prefix] do
          assert_receive %Broadcast{topic: ^topic}
          refute_receive %Broadcast{topic: ^topic}, 50
        end
      end
    end
  end
end
