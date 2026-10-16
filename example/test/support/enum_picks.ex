defmodule Example.Test.EnumPicks.Domain do
  @moduledoc "Holds the resource whose fields are typed by `Ash.Type.Enum` modules."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.EnumPicks.Stage do
  @moduledoc """
  An enum whose labels are not its values humanized, so a page shows which
  one it read: `:live` is "On air", where humanizing would say "Live".
  `:archived` is left to the enum's own default label.
  """
  use Ash.Type.Enum,
    values: [
      draft: [label: "Being written"],
      live: [label: "On air"],
      archived: "Kept for the record"
    ]
end

defmodule Example.Test.EnumPicks.Channel do
  @moduledoc "The item type of a list of enum values, labelled the same way."
  use Ash.Type.Enum, values: [email: [label: "E-mail"], sms: [label: "Text message"]]
end

defmodule Example.Test.EnumPicks.Phase do
  @moduledoc """
  A string-valued enum: what it stores is the string, which still reads as
  its label ("Closed now"), not as itself.
  """
  use Ash.Type.Enum, values: ["open", "closed_now"]
end

defmodule Example.Test.EnumPicks.Size do
  @moduledoc "A new type over a constrained atom, which counts as what it wraps."
  use Ash.Type.NewType, subtype_of: :atom, constraints: [one_of: [:small, :extra_large]]
end

defmodule Example.Test.EnumPicks do
  @moduledoc """
  Fields with a fixed set of values, and a page over them: an
  `Ash.Type.Enum`, a list of another, a string-valued one and a new type over
  a constrained atom. Each is picked from a select, filtered on and shown by
  its labels. Beside them, an atom and a list of atoms without `one_of`,
  which hold no fixed set and are typed in.
  """
  use Ash.Resource,
    domain: Example.Test.EnumPicks.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshQuick]

  alias Example.Test.EnumPicks.{Channel, Phase, Size, Stage}

  actions do
    defaults [
      :read,
      create: [:code, :stage, :channels, :phase, :size],
      update: [:stage, :channels, :phase, :size]
    ]

    # The atoms without `one_of` on a form of their own: a list of them is a
    # text input that posts a string, which the list refuses, so a save
    # through it would fail for a reason that is not this page's.
    create :jot do
      accept [:code, :stage, :mood, :marks]
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
    attribute :stage, Stage, allow_nil?: false, public?: true
    attribute :channels, {:array, Channel}, public?: true, default: []
    attribute :phase, Phase, public?: true
    attribute :size, Size, public?: true
    attribute :mood, :atom, public?: true
    attribute :marks, {:array, :atom}, public?: true, default: []
  end
end

defmodule Example.Test.EnumPicksLive.Quick do
  @moduledoc """
  The page over `Example.Test.EnumPicks`, routed only in the test build — see
  the `:test_routes` block in `ExampleWeb.Router`.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.EnumPicks,
    list: [fields: [:code, :stage, :channels, :phase, :size]],
    details: [fields: [:code, :stage, :channels, :phase, :size]]
end
