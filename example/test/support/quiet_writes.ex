defmodule Example.Test.QuietWrites.Domain do
  @moduledoc "Holds the resource whose updates may change nothing."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.QuietWrites.Note do
  @moduledoc """
  A note on an `Example.Test.QuietWrites` record: what a relationship-only
  update writes, and what `:tally` adds behind its record's back.

  Publishes nothing of its own, so a broadcast on the record's topics can only
  have come from the record's own publications.
  """
  use Ash.Resource,
    domain: Example.Test.QuietWrites.Domain,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, create: [:body, :quiet_write_id]]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :body, :string, allow_nil?: false, public?: true
  end

  relationships do
    belongs_to :quiet_write, Example.Test.QuietWrites do
      public? true
      attribute_writable? true
    end
  end
end

defmodule Example.Test.QuietWrites.Tally do
  @moduledoc """
  Adds a note to the record it runs on, from an `after_action`: the update
  itself writes no attribute of its record, but a page counting the record's
  notes shows something new.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      Example.Test.QuietWrites.Note
      |> Ash.Changeset.for_create(:create, %{body: "tallied", quiet_write_id: record.id})
      |> Ash.create!(authorize?: false)

      {:ok, record}
    end)
  end
end

defmodule Example.Test.QuietWrites do
  @moduledoc """
  A resource with auditing, bookkeeping and versioning all on, whose updates
  may change nothing, and the page over it, routed only in the test build.
  Every update but `:tally` and `:print_unlisted` is listed in
  `liveness quiet`.

    * `:update` is the edit form's, on the in-memory path.
    * `:print` and `:watermark` accept nothing and change no attribute: one
      downloads a PDF of the record, the other marks it with
      `:ash_quick_download`. `:print_unlisted` prints too, but is not quiet.
    * `:rename_atomic` writes its name on the atomic path, and
      `:stamp_atomic` accepts nothing there.
    * `:add_notes` changes only a relationship.
    * `:ping` changes nothing, and has a publication of the resource's own.
    * `:tally` changes no attribute, but adds a note behind its record's back,
      which the page counts. It is not quiet.

  In ETS rather than Postgres: the table is shared by every test, so each one
  works on the records it made.
  """
  use Ash.Resource,
    domain: Example.Test.QuietWrites.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    notifiers: [Ash.Notifier.PubSub],
    authorizers: [Ash.Policy.Authorizer]

  resource do
    plural_name :quiet_writes
  end

  actions do
    defaults [:read, :destroy, create: [:code, :name, :note]]

    read :index do
      argument :search, :string

      pagination do
        keyset? true
        offset? true
        default_limit 250
        max_page_size 250
        countable :by_default
      end
    end

    update :update do
      primary? true
      accept [:name, :note]
      require_atomic? false
    end

    update :print do
      accept []
      require_atomic? false
      change {AshQuick.Print, template: Example.Test.Printable.Sheet, delivery: :download}
    end

    update :print_unlisted do
      accept []
      require_atomic? false
      change {AshQuick.Print, template: Example.Test.Printable.Sheet, delivery: :download}
    end

    update :watermark do
      accept []
      require_atomic? false
      change Example.Test.Downloadable.Watermark
    end

    update :rename_atomic do
      accept [:name]
    end

    update :stamp_atomic do
      accept []
    end

    update :add_notes do
      accept []
      require_atomic? false
      argument :notes, {:array, :map}, allow_nil?: false
      change manage_relationship(:notes, type: :create)
    end

    update :ping do
      accept []
      require_atomic? false
    end

    update :tally do
      accept []
      require_atomic? false
      change Example.Test.QuietWrites.Tally
    end
  end

  policies do
    policy action_type([:create, :update, :destroy]) do
      authorize_if Example.Checks.ActorCanWrite
    end

    policy action_type(:read) do
      authorize_if actor_present()
    end
  end

  ash_quick do
    display do
      label :name
    end

    liveness do
      quiet [:update, :print, :watermark, :rename_atomic, :stamp_atomic, :add_notes, :ping]
    end
  end

  # The resource's own publication: on `"<prefix>:pinged:<id>"`, beside the
  # standard ones AshQuick adds.
  pub_sub do
    module ExampleWeb.Endpoint
    publish :ping, ["pinged", :id]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :code, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :note, :string, public?: true
  end

  relationships do
    has_many :notes, Example.Test.QuietWrites.Note do
      destination_attribute :quiet_write_id
      public? true
    end
  end

  aggregates do
    count :note_count, :notes, public?: true
  end
end

defmodule Example.Test.QuietWritesLive.Quick do
  @moduledoc """
  The page over `Example.Test.QuietWrites`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.QuietWrites,
    list: [fields: [:code, :name]],
    details: [fields: [:code, :name, :note, :note_count]]
end
