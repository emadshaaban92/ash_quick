defmodule AshQuick.LiveView.LivenessTest do
  @moduledoc """
  The topic a details page listens on when its record came back `nil`.

  There is no record to read an id from then, so the topic comes from the URL —
  and a URL may spell an id however the router let it through. Ash publishes the
  id as the data layer holds it, so the URL's id has to be cast the way the read
  casts it, or the page waits on a topic nothing will ever publish to.
  """
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.Liveness
  alias AshQuick.LiveView.QuickView.Options
  alias AshQuick.LiveView.URLParams
  alias Example.Catalog.Product

  @options %Options{
    module: ExampleWeb.ProductLive.Quick,
    resource: Product,
    domain: Example.Catalog,
    liveness_options: []
  }

  defp subscribed(id) do
    subscribe = Keyword.fetch!(Liveness.details_options(@options, %URLParams{id: id}), :subscribe)
    subscribe.(nil)
  end

  test "an upper-cased UUID listens on the topic its record publishes" do
    id = Ash.UUID.generate()

    assert subscribed(String.upcase(id)) == [AshQuick.Topics.record(Product, id)]
  end

  test "an id that does not cast names no record, and listens on nothing" do
    assert subscribed("not-a-uuid") == []
  end

  defmodule Keyless do
    @moduledoc false
    use Ash.Resource, domain: nil, data_layer: Ash.DataLayer.Ets

    attributes do
      uuid_primary_key :uuid
    end

    actions do
      defaults [:read]
    end
  end

  # A QuickView may list a resource without the extension, which need not have
  # an `:id`. It publishes nothing, so its page is simply not live.
  test "a resource with no :id is not live, and does not raise" do
    options = %Options{@options | resource: Keyless}

    assert Liveness.details_options(options, %URLParams{id: Ash.UUID.generate()}) == []
  end
end
