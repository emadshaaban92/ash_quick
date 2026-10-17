defmodule Example.Test.FormStages.Domain do
  @moduledoc "Holds the resource whose change records the form stage it sees."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.FormStages.RecordStage do
  @moduledoc """
  Seeds the `:note` argument, and the `:label` attribute where the action
  accepts it, when a QuickView form is built, the way a host fills a form from
  a computed value as it opens. It also says what it saw:
  on the form, in the `:stage_seen` argument, and on the record, as the stage
  its `change/3` ran under (`:built_stage`) and the stage and `action_source`
  the run carried (`:run_stage`, `:run_source`), read in a `before_action`
  hook, after the run's own context is merged in.
  """
  use Ash.Resource.Change

  @seeded "Seeded as the form opened"

  @seeded_label "Seeded label"

  @doc "What the note is seeded with."
  def seeded, do: @seeded

  @doc "What the label is seeded with."
  def seeded_label, do: @seeded_label

  @impl true
  def change(changeset, _opts, _context) do
    stage = AshQuick.form_stage(changeset)

    changeset =
      if stage == AshQuick.form_build_stage(),
        do: seed(changeset),
        else: changeset

    changeset
    |> Ash.Changeset.set_argument(:stage_seen, stage)
    |> Ash.Changeset.force_change_attribute(:note, Ash.Changeset.get_argument(changeset, :note))
    |> Ash.Changeset.force_change_attribute(:built_stage, stage)
    |> Ash.Changeset.before_action(fn changeset ->
      changeset
      |> Ash.Changeset.force_change_attribute(:run_stage, AshQuick.form_stage(changeset))
      |> Ash.Changeset.force_change_attribute(:run_source, changeset.context[:action_source])
    end)
  end

  defp seed(changeset) do
    changeset = Ash.Changeset.set_argument(changeset, :note, @seeded)

    if :label in changeset.action.accept,
      do: Ash.Changeset.change_attribute(changeset, :label, @seeded_label),
      else: changeset
  end
end

defmodule Example.Test.FormStages do
  @moduledoc """
  A resource whose actions record the form stage they see, and the page over
  it, routed only in the test build. `:create` takes a code, a label, an
  image and a note, and `:renote`, offered as a bulk action, a note alone; both run
  `Example.Test.FormStages.RecordStage`. The image is there to upload: an
  upload validates the form without a `phx-change`.

  In ETS rather than Postgres: nothing here is about what lands in a table. The
  table is shared by every test, so each one finds its own rows by the codes it
  made.
  """
  use Ash.Resource,
    domain: Example.Test.FormStages.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  alias Example.Test.FormStages.RecordStage

  actions do
    defaults [:read]

    create :create do
      primary? true
      accept [:code, :label, :image]
      argument :note, :string
      argument :stage_seen, :atom
      change RecordStage
    end

    update :renote do
      accept []
      require_atomic? false
      argument :note, :string, allow_nil?: false
      argument :stage_seen, :atom
      change RecordStage
    end

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 250
        countable :by_default
      end
    end
  end

  ash_quick do
    display do
      label :code
    end

    versioning do
      enabled? false
    end

    audit do
      enabled? false
    end

    bookkeeping do
      inserted_at false
      inserted_by false
      updated_at false
      updated_by false
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
    attribute :label, :string, public?: true
    attribute :note, :string, public?: true

    attribute :image, :attachment,
      public?: true,
      constraints: [visibility: :private, accepts: [:image], max_size_mb: 10]

    attribute :built_stage, :atom, public?: true
    attribute :run_stage, :atom, public?: true
    attribute :run_source, :atom, public?: true
  end
end

defmodule Example.Test.FormStagesLive.Quick do
  @moduledoc """
  The page over `Example.Test.FormStages`, routed only in the test build — see
  the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.FormStages,
    list: [fields: [:code, :note], bulk_actions: [:renote]],
    details: [fields: [:code, :note]]
end
