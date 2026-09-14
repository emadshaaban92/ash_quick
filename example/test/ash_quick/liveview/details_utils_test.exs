defmodule AshQuick.LiveView.DetailsUtilsTest do
  @moduledoc """
  Two things about the details record load that need a real host.

  The refetch is a regression: a QuickView with `liveness_options: [subscribe:
  ...]` sets up a `keep_live(:record)` on the details page, and that keep_live
  and its refetch hook stay attached when the user patches to the edit form. An
  incoming notification then fires `{:refetch, :record}` while `ash_action` is
  `:update`, so `load_record!/3` has to refetch with a *read* action —
  building `Ash.Query.for_read/4` against the update action raised and took the
  LiveView with it.

  The actor load is the other: it is built from each resource's bookkeeping
  declaration, so what pins it is having resources that declare different
  amounts of it. An application configures exactly one actor resource, so no
  page can be opened against a second one whose label is a different field, and
  a hardcoded `:name` would pass every UI test there is.
  """
  use Example.DataCase, async: true

  alias AshQuick.LiveView.QuickView.Options
  alias AshQuick.LiveView.{DetailsUtils, URLParams}
  alias Example.Catalog.Product

  test "load_record!/3 refetches with a read action even while the action is :update",
       %{admin: admin} do
    product = product(actor: admin)

    options = %Options{
      module: ExampleWeb.ProductLive.Quick,
      resource: Product,
      domain: Example.Catalog,
      details_fields: [],
      details_load: [],
      load: [],
      details_default_action: :read
    }

    # A stale details keep_live firing after a patch to the edit form: the
    # current action is :update, not a read.
    socket = %{
      assigns: %{
        ash_action: Ash.Resource.Info.action(Product, :update),
        scope: Example.Scope.new(actor: admin)
      }
    }

    params = %URLParams{id: product.id, read_args: %{}}

    record = DetailsUtils.load_record!(socket, params, options)
    assert record.id == product.id
  end

  test "the actor load asks the actor resource what its records are called" do
    actor = AshQuick.Config.actor_resource()
    label = AshQuick.Info.display_label(actor)

    assert DetailsUtils.actor_load(Product) == [created_by: [label], updated_by: [label]]

    # Built from what each resource declared, so an append-only resource never
    # names the relationship it does not have, and one that carries none of the
    # four asks for nothing.
    assert DetailsUtils.actor_load(Example.Catalog.PriceChange) == [created_by: [label]]
    assert DetailsUtils.actor_load(Example.Accounts.AuditLog) == []
  end
end
