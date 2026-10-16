defmodule Example.Test.Printable.Domain do
  @moduledoc "Holds the resource whose actions print."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.Printable.Sheet do
  @moduledoc """
  A page per record, its code over its name. Each page carries the name in a
  `data-name` attribute too, which is what a test reads the order of the
  printed records off.
  """
  @behaviour AshQuick.PrintTemplate

  @impl true
  def label, do: "Sheet"

  @impl true
  def load_opts, do: []

  @impl true
  def render(records) do
    pages =
      Enum.map_join(records, "\n", fn record ->
        ~s(<section data-name="#{escape(record.name)}">) <>
          "<h1>#{escape(record.code)}</h1><p>#{escape(record.name)}</p></section>"
      end)

    "<html><body>#{pages}</body></html>"
  end

  defp escape(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end

defmodule Example.Test.Printable.FaultySheet do
  @moduledoc """
  A print template that cannot render. It names the records it was handed in
  what it raises, so a test can tell its own failure from another's in a log.
  """
  @behaviour AshQuick.PrintTemplate

  @impl true
  def label, do: "Faulty Sheet"

  @impl true
  def load_opts, do: []

  @impl true
  def render(records), do: raise("cannot render #{Enum.map_join(records, ", ", & &1.name)}")
end

defmodule Example.Test.Printable do
  @moduledoc """
  A resource whose actions print, and the page over it, routed only in the
  test build. Printing needs a renderer, and only `config/test.exs` names one
  (`Example.Test.PdfRendererDouble`), so these actions exist only where they
  can run: `AshQuick.Print.Verifier` would refuse them anywhere else.

  Each print records when it ran (`:printed_at`), so it is a real write that
  takes the optimistic lock, the way a host's print would be:

    * `:print` takes no input, so it is offered as a row action, in the derived
      bulk menu and on the details page, and downloads its PDF.
    * `:rename_and_print` takes a name, so it runs from its form, and opens the
      browser's print dialog on what it wrote.
    * `:print_if_active` prints, and records the print of, only the records
      that are active; an inactive one is left as it was.
    * `:print_faulty` prints through a template that raises: the write stays,
      and the page says its PDF could not be produced.

  In ETS rather than Postgres: nothing here is about what lands in a table. The
  table is shared by every test, so each one finds its own rows by the names it
  made, and the page shows enough rows that none is pushed off it.
  """
  use Ash.Resource,
    domain: Example.Test.Printable.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  alias Example.Test.Printable.{FaultySheet, Sheet}

  resource do
    plural_name :printables
  end

  # Written once, so the record of a print and the print itself cannot come to
  # disagree about which rows they cover.
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

    update :print do
      accept []
      change set_attribute(:printed_at, &DateTime.utc_now/0)
      change {AshQuick.Print, template: Sheet, delivery: :download}
    end

    update :rename_and_print do
      accept [:name]
      change set_attribute(:printed_at, &DateTime.utc_now/0)
      change {AshQuick.Print, template: Sheet, delivery: :print}
    end

    update :print_if_active do
      accept []
      change set_attribute(:printed_at, &DateTime.utc_now/0), where: @active
      change {AshQuick.Print, template: Sheet}, where: @active
    end

    update :print_faulty do
      accept []
      change set_attribute(:printed_at, &DateTime.utc_now/0)
      change {AshQuick.Print, template: FaultySheet}
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
    attribute :printed_at, :utc_datetime_usec, public?: true
  end
end

defmodule Example.Test.PrintableLive.Quick do
  @moduledoc """
  The page over `Example.Test.Printable`, routed only in the test build — see
  the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.Printable,
    list: [fields: [:code, :name, :active]],
    details: [fields: [:code, :name, :active, :printed_at]]
end
