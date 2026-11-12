defmodule Example.Test.Downloadable.Domain do
  @moduledoc "Holds the resource whose actions produce a file."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.Downloadable.Watermark do
  @moduledoc """
  Stands in for an action that produces a file of its own, a watermarked copy
  of an upload say: it marks the record it returns with `:ash_quick_download`.

  The "file" is the record's name behind two bytes no UTF-8 string holds, so a
  test sees the bytes go through base64 as bytes. `mark: :malformed` marks
  the record with a map missing its `:content_type` and holding a number for
  its `:data`, the mistake a host's own change could make.
  """
  use Ash.Resource.Change

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      {:ok, Ash.Resource.put_metadata(record, :ash_quick_download, mark(record, opts[:mark]))}
    end)
  end

  # An `after_action` runs on the atomic path too, so the update need not give
  # it up.
  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  @doc "The bytes `:watermark` delivers for `record`."
  def bytes(record), do: <<0xFF, 0x00>> <> "watermarked " <> record.name

  @doc "The name `:watermark` saves `record`'s file under."
  def filename(record), do: "#{record.code}-watermarked.bin"

  defp mark(record, :malformed), do: %{data: 42, filename: filename(record)}

  defp mark(record, _valid) do
    %{data: bytes(record), filename: filename(record), content_type: "application/octet-stream"}
  end
end

defmodule Example.Test.Downloadable do
  @moduledoc """
  A resource whose actions produce a file, and the page over it, routed only
  in the test build. Each action records when it ran (`:watermarked_at`), so
  it is a real write that takes the optimistic lock:

    * `:watermark` takes no input, so it is offered as a row action, in the
      derived bulk menu and on the details page.
    * `:rename_and_watermark` takes a name, so it runs from its form, and
      delivers a file of what it wrote.
    * `:watermark_if_active` marks only the records that are active.
    * `:watermark_malformed` marks its record with a mark AshQuick cannot
      deliver.
    * `:touch` writes and marks nothing.

  In ETS rather than Postgres: the table is shared by every test, so each one
  finds its own rows by the names it made.
  """
  use Ash.Resource,
    domain: Example.Test.Downloadable.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  alias Example.Test.Downloadable.Watermark

  resource do
    plural_name :downloadables
  end

  @active [Ash.Resource.Validation.Builtins.attribute_equals(:active, true)]

  actions do
    defaults [:read, :destroy, create: [:code, :name, :active]]

    read :index do
      argument :search, :string

      prepare build(sort: [name: :asc])

      pagination do
        keyset? true
        offset? true
        default_limit 250
        max_page_size 250
        countable :by_default
      end
    end

    update :watermark do
      accept []
      change set_attribute(:watermarked_at, &DateTime.utc_now/0)
      change Watermark
    end

    update :rename_and_watermark do
      accept [:name]
      change set_attribute(:watermarked_at, &DateTime.utc_now/0)
      change Watermark
    end

    update :watermark_if_active do
      accept []
      change set_attribute(:watermarked_at, &DateTime.utc_now/0), where: @active
      change Watermark, where: @active
    end

    update :watermark_malformed do
      accept []
      change set_attribute(:watermarked_at, &DateTime.utc_now/0)
      change {Watermark, mark: :malformed}
    end

    update :touch do
      accept []
      change set_attribute(:watermarked_at, &DateTime.utc_now/0)
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
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :active, :boolean, allow_nil?: false, default: true, public?: true
    attribute :watermarked_at, :utc_datetime_usec, public?: true
  end
end

defmodule Example.Test.DownloadableLive.Quick do
  @moduledoc """
  The page over `Example.Test.Downloadable`, routed only in the test build —
  see the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.Downloadable,
    list: [fields: [:code, :name, :active]],
    details: [fields: [:code, :name, :active, :watermarked_at]]
end
