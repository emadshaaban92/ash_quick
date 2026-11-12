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

  require Ash.Query

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

  defmodule Gen do
    @moduledoc false
    def token, do: "t-#{System.unique_integer([:positive])}"
  end

  # Writes `status` from an argument in a `before_action`, and nothing on
  # the atomic path.
  defmodule HookStatus do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.before_action(changeset, fn changeset ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :status,
          Ash.Changeset.get_argument(changeset, :hook_status)
        )
      end)
    end

    @impl true
    def atomic(changeset, _opts, _context), do: {:ok, changeset}
  end

  defmodule Tag do
    @moduledoc false
    use Ash.Resource,
      domain: AshQuick.ReadOnlyFieldsTest.Domain,
      data_layer: Ash.DataLayer.Ets

    ets do
      private? true
    end

    actions do
      defaults [:read, :destroy, create: [:name, :card_id]]
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
      attribute :card_id, :uuid, public?: true
    end
  end

  # Arguments an action's own changes consume: one managed into a
  # relationship, one copied into an attribute.
  defmodule Card do
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
        read_only :tag_inputs, writable_if: ActorHasRole
        read_only :label, writable_if: ActorHasRole
        read_only :status, writable_if: ActorHasRole
        read_only :speed, writable_if: ActorHasRole
        read_only :priority, writable_if: ActorHasRole
        read_only :code, writable_if: ActorHasRole
        read_only :summary, writable_if: ActorHasRole
        read_only :token, writable_if: ActorHasRole
        read_only :ref, writable_if: ActorHasRole
      end
    end

    actions do
      defaults [:read, :destroy]

      create :create do
        primary? true
        accept [:name, :status]
        argument :tag_inputs, {:array, :map}
        argument :label, :string

        change manage_relationship(:tag_inputs, :tags, type: :create)
        change set_attribute(:title, arg(:label))
      end

      update :update do
        primary? true
        require_atomic? false
        accept [:name, :status]
        argument :tag_inputs, {:array, :map}
        argument :label, :string

        change manage_relationship(:tag_inputs, :tags, type: :create)
        change set_attribute(:title, arg(:label))
      end

      update :retitle do
        argument :label, :string
        change set_attribute(:title, arg(:label))
      end

      update :rename_status do
        argument :new_status, :string
        change set_attribute(:status, arg(:new_status))
      end

      create :with_speed do
        accept [:name]
        argument :speed, :string, default: "standard"
        change set_attribute(:mode, arg(:speed))
      end

      create :with_priority do
        accept [:name, :priority]
      end

      update :reprioritize do
        accept [:priority]
      end

      create :with_code do
        accept [:name]
        argument :code, :string, allow_nil?: false
        change set_attribute(:title, arg(:code))
      end

      create :invite do
        accept [:name]
        argument :token, :string, default: &AshQuick.ReadOnlyFieldsTest.Gen.token/0
        change set_attribute(:title, arg(:token))

        change after_action(fn changeset, record, _context ->
                 {:ok,
                  Ash.Resource.put_metadata(
                    record,
                    :sent_token,
                    Ash.Changeset.get_argument(changeset, :token)
                  )}
               end)
      end

      create :with_ref do
        accept [:name, :ref]

        change fn changeset, _context ->
          Ash.Changeset.force_change_attribute(
            changeset,
            :mode,
            Ash.Changeset.get_attribute(changeset, :ref)
          )
        end
      end

      destroy :archive do
        soft? true
        require_atomic? false
        accept [:status]
        change set_attribute(:archived, true)
      end

      create :draft do
        accept [:name, :status]
        change set_attribute(:status, "draft")
      end

      update :hooked do
        require_atomic? false
        argument :hook_status, :string

        change fn changeset, _context ->
          Ash.Changeset.before_action(changeset, fn changeset ->
            Ash.Changeset.force_change_attribute(
              changeset,
              :status,
              Ash.Changeset.get_argument(changeset, :hook_status)
            )
          end)
        end
      end

      # Not `require_atomic? false`: a single update writes atomically and
      # runs no hook, but a `bulk_update` streaming the records runs it.
      update :hooked_atomic do
        argument :hook_status, :string
        change AshQuick.ReadOnlyFieldsTest.HookStatus
      end

      # ETS fills a function default again on insert, so what a data layer
      # such as Postgres would insert is read off the changeset itself.
      create :stamped do
        accept [:name, :ref]

        change after_action(fn changeset, record, _context ->
                 {:ok,
                  Ash.Resource.put_metadata(
                    record,
                    :inserted_ref,
                    Map.fetch(changeset.attributes, :ref)
                  )}
               end)
      end

      create :with_summary do
        accept [:name]
        argument :summary, :string
        validate present(:summary)
      end
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
      attribute :status, :string, public?: true
      attribute :title, :string, public?: true
      attribute :mode, :string, public?: true
      attribute :archived, :boolean, public?: true, default: false
      attribute :ref, :string, public?: true, default: &AshQuick.ReadOnlyFieldsTest.Gen.token/0
      attribute :priority, :string, public?: true, default: "normal", update_default: "reset"
    end

    relationships do
      has_many :tags, AshQuick.ReadOnlyFieldsTest.Tag,
        destination_attribute: :card_id,
        public?: true
    end
  end

  # An extension whose transformer adds an update after the read-only
  # transformer has run, so the action carries no strip of its own.
  defmodule LateActionTransformer do
    @moduledoc false
    use Spark.Dsl.Transformer

    @impl true
    def after?(AshQuick.ReadOnlyFields.Transformer), do: true
    def after?(_), do: false

    @impl true
    def before?(Ash.Resource.Transformers.ValidationsAndChangesForType), do: true
    def before?(_), do: false

    @impl true
    def transform(dsl_state) do
      {:ok, action} =
        Spark.Dsl.Transformer.build_entity(Ash.Resource.Dsl, [:actions], :update,
          name: :late_update,
          accept: [:status]
        )

      {:ok, Spark.Dsl.Transformer.add_entity(dsl_state, [:actions], action)}
    end
  end

  defmodule LateAction do
    @moduledoc false
    use Spark.Dsl.Extension, transformers: [LateActionTransformer]
  end

  defmodule Late do
    @moduledoc false
    use Ash.Resource,
      domain: AshQuick.ReadOnlyFieldsTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshQuick, AshQuick.ReadOnlyFieldsTest.LateAction]

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
      end
    end

    actions do
      defaults [:read, :destroy, create: [:name, :status], update: [:name, :status]]
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
      attribute :status, :string, public?: true
    end
  end

  # Upserts need an identity, and on ETS an identity is checked in a
  # `before_action`, which no atomic update can run: so a resource of its own.
  defmodule Account do
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
        read_only :priority, writable_if: ActorHasRole
        read_only :ref, writable_if: ActorHasRole
      end
    end

    actions do
      defaults [:read]

      create :upsert do
        primary? true
        accept [:email, :name, :priority, :ref]
        upsert? true
        upsert_identity :unique_email
      end

      # Writes the value the default would give, which is still a write.
      create :upsert_normal do
        accept [:email, :name, :priority]
        upsert? true
        upsert_identity :unique_email
        change set_attribute(:priority, "normal")
      end
    end

    attributes do
      uuid_primary_key :id
      attribute :email, :string, public?: true
      attribute :name, :string, public?: true
      attribute :priority, :string, public?: true, default: "normal"
      attribute :ref, :string, public?: true, default: &AshQuick.ReadOnlyFieldsTest.Gen.token/0
    end

    identities do
      identity :unique_email, [:email], pre_check_with: AshQuick.ReadOnlyFieldsTest.Domain
    end
  end

  defp context(role), do: %Context{actor: %{role: role}}

  defp upsert(params, role, action \\ :upsert) do
    Account
    |> Ash.Changeset.for_create(action, params, actor: %{role: role})
    |> Ash.create!(authorize?: false)
  end

  defp create_card(action, params, role) do
    Card
    |> Ash.Changeset.for_create(action, params, actor: %{role: role})
    |> Ash.create!(authorize?: false, load: [:tags])
  end

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

  test "an argument an action's change manages into a relationship is dropped" do
    card = create_card(:create, %{name: "c", tag_inputs: [%{name: "t"}]}, :viewer)
    assert card.tags == []

    card = create_card(:create, %{name: "c", tag_inputs: [%{name: "t"}]}, :admin)
    assert [%{name: "t"}] = card.tags
  end

  test "an argument an action's change copies into an attribute is dropped" do
    assert %{title: nil} = create_card(:create, %{name: "c", label: "l"}, :viewer)
    assert %{title: "l"} = create_card(:create, %{name: "c", label: "l"}, :admin)
  end

  test "an update drops a consumed argument too" do
    card = create_card(:create, %{name: "c"}, :admin)

    updated =
      card
      |> Ash.Changeset.for_update(:update, %{tag_inputs: [%{name: "t"}], label: "l"},
        actor: %{role: :viewer}
      )
      |> Ash.update!(authorize?: false, load: [:tags])

    assert %{title: nil, tags: []} = updated
  end

  test "the atomic path drops a consumed argument too" do
    card = create_card(:create, %{name: "c"}, :admin)

    assert %{title: nil} =
             card
             |> Ash.Changeset.for_update(:retitle, %{label: "l"}, actor: %{role: :viewer})
             |> Ash.update!(authorize?: false)

    assert %{title: "l"} =
             card
             |> Ash.Changeset.for_update(:retitle, %{label: "l"}, actor: %{role: :admin})
             |> Ash.update!(authorize?: false)
  end

  test "a read-only attribute an action's change fills from another input is cleared" do
    card = create_card(:create, %{name: "c", status: "orig"}, :admin)

    assert %{status: "orig"} =
             card
             |> Ash.Changeset.for_update(:rename_status, %{new_status: "forged"},
               actor: %{role: :viewer}
             )
             |> Ash.update!(authorize?: false)
  end

  test "an action another extension adds after the transformer is still stripped" do
    note =
      Late
      |> Ash.Changeset.for_create(:create, %{status: "s"}, actor: %{role: :admin})
      |> Ash.create!(authorize?: false)

    refute Enum.any?(
             Ash.Resource.Info.action(Late, :late_update).changes,
             &match?(%{change: {AshQuick.ReadOnlyFields.StripReadOnlyFields, _}}, &1)
           )

    assert %{status: "s"} =
             note
             |> Ash.Changeset.for_update(:late_update, %{status: "x"}, actor: %{role: :viewer})
             |> Ash.update!(authorize?: false)
  end

  describe "a refused input acts as if it was never sent" do
    test "an argument's default still applies" do
      assert %{mode: "standard"} = create_card(:with_speed, %{name: "n"}, :viewer)
      assert %{mode: "standard"} = create_card(:with_speed, %{name: "n", speed: "fast"}, :viewer)
      assert %{mode: "fast"} = create_card(:with_speed, %{name: "n", speed: "fast"}, :admin)
    end

    test "an attribute's default still applies" do
      assert %{priority: "normal"} = create_card(:with_priority, %{name: "n"}, :viewer)

      card = create_card(:with_priority, %{name: "n", priority: "high"}, :viewer)
      assert %{priority: "normal"} = card

      assert %{priority: "reset"} =
               card
               |> Ash.Changeset.for_update(:reprioritize, %{priority: "high"},
                 actor: %{role: :viewer}
               )
               |> Ash.update!(authorize?: false)
    end

    test "a required argument is reported missing" do
      changeset =
        Ash.Changeset.for_create(Card, :with_code, %{name: "n", code: "c"},
          actor: %{role: :viewer}
        )

      refute changeset.valid?

      assert Enum.any?(
               changeset.errors,
               &match?(%Ash.Error.Changes.Required{field: :code, type: :argument}, &1)
             )

      assert %{title: "c"} = create_card(:with_code, %{name: "n", code: "c"}, :admin)
    end

    test "the action's validations see it absent" do
      refute Ash.Changeset.for_create(Card, :with_summary, %{name: "n", summary: "s"},
               actor: %{role: :viewer}
             ).valid?

      assert Ash.Changeset.for_create(Card, :with_summary, %{name: "n", summary: "s"},
               actor: %{role: :admin}
             ).valid?
    end
  end

  describe "a function default is resolved once" do
    test "an argument's: the stored and the sent token agree" do
      card = create_card(:invite, %{name: "n", token: "mine"}, :viewer)

      assert "t-" <> _ = card.title
      assert card.title == card.__metadata__.sent_token
    end

    test "an attribute's: a change that copied it agrees with what is stored" do
      card = create_card(:with_ref, %{name: "n", ref: "mine"}, :viewer)

      assert "t-" <> _ = card.ref
      assert card.ref == card.mode
    end
  end

  describe "an upsert by a refused actor" do
    test "leaves the existing row's read-only fields alone" do
      email = "u-#{System.unique_integer([:positive])}@example.com"

      upsert(%{email: email, name: "a", priority: "high", ref: "keep"}, :admin)

      assert %{priority: "high", ref: "keep", name: "n"} =
               upsert(%{email: email, name: "n"}, :viewer)

      assert %{priority: "high", ref: "keep"} =
               upsert(%{email: email, name: "n", priority: "low", ref: "x"}, :viewer)
    end

    test "an action's own write of the default value is undone too" do
      email = "u-#{System.unique_integer([:positive])}@example.com"

      upsert(%{email: email, name: "a", priority: "high"}, :admin)

      assert %{priority: "high"} =
               upsert(%{email: email, name: "n"}, :viewer, :upsert_normal)

      assert %{priority: "normal"} =
               upsert(%{email: email, name: "n"}, :admin, :upsert_normal)
    end

    test "a new row still gets the defaults" do
      email = "u-#{System.unique_integer([:positive])}@example.com"

      assert %{priority: "normal", ref: "t-" <> _} =
               upsert(%{email: email, name: "n", priority: "low"}, :viewer)
    end
  end

  test "a destroy that accepts a read-only field drops it" do
    card = create_card(:create, %{name: "c", status: "orig"}, :admin)

    assert :ok =
             card
             |> Ash.Changeset.for_destroy(:archive, %{status: "forged"}, actor: %{role: :viewer})
             |> Ash.destroy!(authorize?: false)

    assert [%{status: "orig", archived: true}] =
             Card |> Ash.Query.filter(id == ^card.id) |> Ash.read!(authorize?: false)
  end

  test "a function default Ash fills is inserted" do
    card = create_card(:stamped, %{name: "n"}, :viewer)
    assert {:ok, "t-" <> _ = ref} = card.__metadata__.inserted_ref
    assert card.ref == ref

    card = create_card(:stamped, %{name: "n", ref: "mine"}, :viewer)
    assert {:ok, "t-" <> _} = card.__metadata__.inserted_ref
  end

  test "a bulk create inserts a function default too" do
    assert %Ash.BulkResult{status: :success, records: [card]} =
             Ash.bulk_create([%{name: "n"}], Card, :stamped,
               actor: %{role: :viewer},
               authorize?: false,
               return_records?: true
             )

    assert {:ok, "t-" <> _} = card.__metadata__.inserted_ref
  end

  test "a value a before_action hook writes is undone on a streamed bulk update" do
    card = create_card(:create, %{name: "c", status: "orig"}, :admin)

    assert %Ash.BulkResult{status: :success, records: [updated]} =
             Ash.bulk_update([card], :hooked_atomic, %{hook_status: "forged"},
               strategy: :stream,
               actor: %{role: :viewer},
               authorize?: false,
               return_records?: true
             )

    assert %{status: "orig"} = updated

    assert %{status: "orig"} =
             card
             |> Ash.Changeset.for_update(:hooked_atomic, %{hook_status: "forged"},
               actor: %{role: :viewer}
             )
             |> Ash.update!(authorize?: false)
  end

  test "a value a before_action hook writes is undone" do
    card = create_card(:create, %{name: "c", status: "orig"}, :admin)

    assert %{status: "orig"} =
             card
             |> Ash.Changeset.for_update(:hooked, %{hook_status: "forged"},
               actor: %{role: :viewer}
             )
             |> Ash.update!(authorize?: false)
  end

  # `read_only` means a covered action does not write the field at all for a
  # refused actor, whether from input or from the action's own change. Only a
  # default is left.
  test "an action's own write is undone too" do
    assert %{status: nil} = create_card(:draft, %{name: "c"}, :viewer)
    assert %{status: "draft"} = create_card(:draft, %{name: "c"}, :admin)
  end
end
