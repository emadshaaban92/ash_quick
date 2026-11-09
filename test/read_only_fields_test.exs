defmodule AshQuick.ReadOnlyFieldsTest do
  @moduledoc """
  What `AshQuick.ReadOnlyFields.Info.writable?/4` answers, and what the change
  `read_only_fields` prepends drops: a field is writable where no entry covers
  it, and otherwise where its `writable_if:` check says so, with a raising
  check read as a refusal and a `{Module, opts}` tuple handing its opts on.
  """
  use ExUnit.Case, async: true

  alias AshQuick.ReadOnlyFields.Check.Context
  alias AshQuick.ReadOnlyFields.Info

  defmodule ActorHasRole do
    @moduledoc false
    @behaviour AshQuick.ReadOnlyFields.Check

    @impl true
    def match?(%{actor: %{role: role}}, opts), do: role == Keyword.get(opts, :role, :admin)
    def match?(_context, _opts), do: false
  end

  defmodule Raises do
    @moduledoc false
    @behaviour AshQuick.ReadOnlyFields.Check

    @impl true
    def match?(_context, _opts), do: raise("broken check")
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule Note do
    @moduledoc false
    use Ash.Resource,
      domain: AshQuick.ReadOnlyFieldsTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshQuick]

    ets do
      private? true
    end

    ash_quick do
      liveness do
        enabled? false
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

      audit do
        enabled? false
      end

      read_only_fields do
        read_only :status, writable_if: ActorHasRole
        read_only :owner, writable_if: {ActorHasRole, role: :editor}, on: [:create]
        read_only :code, writable_if: Raises
      end
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept [:name, :status, :owner, :code]
      end

      update :update do
        primary? true
        accept [:name, :status, :owner, :code]
      end
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
      attribute :status, :string, public?: true
      attribute :owner, :string, public?: true
      attribute :code, :string, public?: true
    end
  end

  defp context(role), do: %Context{actor: %{role: role}}

  test "a field no entry covers is writable" do
    assert Info.writable?(Note, :create, :name, context(:viewer))
    assert Info.writable?(Note, :update, :owner, context(:viewer))
  end

  test "a covered field is writable for an actor the check lets through" do
    assert Info.writable?(Note, :update, :status, context(:admin))
    refute Info.writable?(Note, :update, :status, context(:viewer))
    refute Info.writable?(Note, :update, :status, %Context{})
  end

  test "a {Module, opts} check gets its opts" do
    assert Info.writable?(Note, :create, :owner, context(:editor))
    refute Info.writable?(Note, :create, :owner, context(:admin))
  end

  test "a check that raises reads as not writable" do
    refute Info.writable?(Note, :create, :code, context(:admin))
  end

  test "the changeset drops what the actor may not write and keeps the rest" do
    note =
      Note
      |> Ash.Changeset.for_create(
        :create,
        %{name: "t", status: "s", owner: "o", code: "c"},
        actor: %{role: :editor}
      )
      |> Ash.create!(authorize?: false)

    assert %{name: "t", status: nil, owner: "o", code: nil} = note
  end
end
