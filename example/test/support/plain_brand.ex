defmodule Example.Test.PlainBrand.Domain do
  @moduledoc "Holds the resource that declares none of AshQuick's capabilities."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule Example.Test.PlainBrand do
  @moduledoc """
  `Example.Catalog.Brand`'s table, read and written by a resource that opts out
  of everything the real one declares.

  Several of AshQuick's capabilities are only visible where a resource has them
  and an otherwise identical one does not — and no resource in this application
  disagrees with itself, so the disagreement is built here. Same table, same
  columns, same rows; the one thing that differs is the `ash_quick` block.

  Two pairings use it:

    * **Activation.** A resource can carry an `:active` column that belongs to
      another extension entirely. AshQuick reads the *declaration*, so a
      deactivated row that `Example.Catalog.Brand` withholds from a dropdown
      survives the same query here.
    * **Versioning.** The optimistic lock is what a `versioning` block switches
      on, not something incidental to updating a record. Two concurrent writes
      through here both land; through `Example.Catalog.Brand` the second is
      refused.

  Nothing routes a page at it: the point is the contrast with the rows a real
  page is already showing, not a second page to look at.
  """
  require Ash.Query

  use Ash.Resource,
    domain: Example.Test.PlainBrand.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshQuick]

  postgres do
    table "brands"
    repo Example.Repo
  end

  actions do
    default_accept [:name]

    # Rows are created through `Example.Catalog.Brand`, which is what makes this
    # the same row seen through a different declaration rather than a lookalike
    # written beside it.
    defaults [:read, :update]

    read :index do
      argument :search, :string

      prepare fn query, _context ->
        case Ash.Query.get_argument(query, :search) do
          blank when blank in [nil, ""] -> query
          search -> Ash.Query.filter(query, contains(name, ^search))
        end
      end

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end
  end

  ash_quick do
    display do
      label :name
    end

    # Off, so a concurrent write is not refused and no `:version` attribute is
    # generated. The column stays in the table — it belongs to the resource that
    # does declare versioning — and is simply not this resource's business.
    versioning do
      enabled? false
    end

    # Off, so the trail of the rows it shares stays `Example.Catalog.Brand`'s.
    audit do
      enabled? false
    end

    bookkeeping do
      created_at false
      created_by false
      updated_at false
      updated_by false
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :code, :string, allow_nil?: false, public?: true
    attribute :name, :string, allow_nil?: false, public?: true

    # Written out rather than declared, which is the whole point: the column is
    # here and the `activation` block is not.
    attribute :active, :boolean, allow_nil?: false, public?: true, default: true
  end
end
