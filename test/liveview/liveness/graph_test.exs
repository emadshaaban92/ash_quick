defmodule AshQuick.LiveView.Liveness.GraphTest do
  @moduledoc """
  What the live-update walk finds behind a record that has no `:id`.

  A join row keyed by the two ids it joins is the record most likely to stand
  between a page and what it renders — a user's memberships, and the
  organizations behind them. It has no topic of its own, but the walk has to
  pass through it, or the organizations never live-update and `explain/1` never
  mentions the rows it passed over.

  The records are built as structs rather than read: the walk looks at what
  materialized, not at how it got there.
  """
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.Liveness.Graph

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule User do
    @moduledoc false
    use Ash.Resource, domain: Domain, extensions: [AshQuick]

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    relationships do
      has_many :memberships, AshQuick.LiveView.Liveness.GraphTest.Membership
    end

    ash_quick do
      display do
        label :name
      end

      versioning do
        enabled? false
      end

      bookkeeping do
        inserted_at false
        updated_at false
        inserted_by false
        updated_by false
      end
    end
  end

  defmodule Organization do
    @moduledoc false
    use Ash.Resource, domain: Domain, extensions: [AshQuick]

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    ash_quick do
      display do
        label :name
      end

      versioning do
        enabled? false
      end

      bookkeeping do
        inserted_at false
        updated_at false
        inserted_by false
        updated_by false
      end
    end
  end

  # Not an AshQuick resource: AshQuick requires an `:id`, and a join row has
  # none.
  defmodule Membership do
    @moduledoc false
    use Ash.Resource, domain: Domain

    attributes do
      attribute :role, :string, public?: true
    end

    relationships do
      belongs_to :user, User, primary_key?: true, allow_nil?: false
      belongs_to :organization, Organization, primary_key?: true, allow_nil?: false
    end
  end

  defp membership(user, organization) do
    %Membership{
      user_id: user.id,
      organization_id: organization.id,
      organization: organization
    }
  end

  setup do
    acme = %Organization{id: Ash.UUID.generate(), name: "Acme"}
    globex = %Organization{id: Ash.UUID.generate(), name: "Globex"}
    user = %User{id: Ash.UUID.generate(), name: "Ada"}

    user = %{user | memberships: [membership(user, acme), membership(user, globex)]}

    %{user: user, acme: acme, globex: globex}
  end

  test "walks through a composite-key join row to the records behind it", ctx do
    {watchable, _skipped} = Graph.walk(ctx.user)

    assert Enum.sort(watchable) ==
             Enum.sort([
               {User, ctx.user.id},
               {Organization, ctx.acme.id},
               {Organization, ctx.globex.id}
             ])
  end

  test "counts the join rows it passed over as skipped", ctx do
    assert {_watchable, %{Membership => 2}} = Graph.walk(ctx.user)
  end

  test "counts a join row reached twice once", ctx do
    assert {_watchable, %{Membership => 2}} = Graph.walk([ctx.user, ctx.user])
  end

  test "stops at a join row whose key is not all there", ctx do
    unsaved = %Membership{user_id: ctx.user.id, organization: ctx.acme}
    user = %{ctx.user | memberships: [unsaved]}

    assert Graph.walk(user) == {[{User, ctx.user.id}], %{}}
  end
end
