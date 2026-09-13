defmodule AshQuick.Info do
  @moduledoc """
  Introspection for the capabilities a resource declares under `ash_quick`.

  AshQuick's views are written against resources they have never seen, so they
  have to ask questions about one — "what is this record called?" being the
  first. Everything here reads an answer off the resource.

  ## Display label

  `display_label/1` names the field a record is labelled by and
  `display_value/1` reads it off a record. The resource declares it:

      ash_quick do
        display do
          label :code
        end
      end

  `label` names an attribute, calculation or aggregate. It is a field name and
  not an expression: a composed label belongs in a calculation, which keeps
  every label loadable through one path. A label naming no such field of the
  resource is a compile error.

  Undeclared, `AshQuick.Display.Transformer` fills it in with `:display_name`,
  then `:name`, while the resource compiles; a resource matching neither
  convention declares one or does not compile. The conventions live there and
  only there — everything here reads back what the transformer wrote, so a
  resource carrying the extension always has an answer and nothing is matched at
  render time.

  A resource without the extension has no answer at all: no transformer ran, so
  there is nothing to read. `display_label/1` says so rather than guessing, and
  `AshQuick.LiveView.QuickView.Options` refuses such a resource when the
  QuickView compiles.

  ## Lookup

  `lookup_action/1` names the read action a search runs through and
  `lookup_search_argument/1` the argument the search text arrives as. The
  resource declares them:

      ash_quick do
        lookup do
          action :index
          search_argument :search
        end
      end

  Both have defaults, so a resource following the convention declares nothing.
  Unlike the label, there is no inference step and nothing is written back
  during compilation — the answer is the declaration or its default, and what
  makes it trustworthy is that it is *checked* rather than resolved:
  `AshQuick.Lookup.Verifier` holds a declared action to the three things every
  caller needs of it, and `AshQuick.LiveView.QuickView.Options` holds the
  reachable ones to the same three while the QuickView compiles.

  A resource without the extension raises here for the same reason it does for
  the label: nothing declared an answer, and guessing `:index` would produce a
  query that fails at read time instead of a wiring error at the call site.

  ## Identity

  Nothing here reads `:id`, and every AshQuick view does. A list row's DOM ids
  are built from it, the row-action events push it back over the socket to name
  the record clicked, and a details route is `/<path>/:id`. So the extension
  carries a second guarantee alongside the label: every resource that has it has
  an `:id` attribute that addresses one row, held by `AshQuick.Identity.Verifier`
  at compile time. It is a separate guarantee in both directions — a resource can
  have an `:id` and no resolvable label, or a good label and no `:id`, and each
  fails on its own.

  Addressing one row is uniqueness, so the verifier holds that too: `:id` is
  either the primary key or carries an identity of its own. A details query
  reads `id == ^id` through `Ash.read_one/2` and a row action finds the first
  matching `:id` on the page, so a repeated one renders not-found in the first
  place and acts on an arbitrary row in the second.

  What the guarantee does *not* say is that `:id` is the primary key, or that it
  is a uuid. A surrogate key is simply the ordinary way to get one — a resource
  keyed on something else qualifies by declaring `identity :unique_id, [:id]` —
  and a composite-keyed join resource is the realistic way to be without: it
  either gains one or does not carry the extension.

  Embedded resources are included in that, and the answer for them is to not
  carry the extension. An embedded value is a field of another record rather
  than a row a QuickView lists — it has no route, no row actions and no
  identity to address — and `AshQuick.LiveView.Components.FieldValue` already
  excludes it from the label path. One carrying the extension is almost
  certainly a mistake, and the verifier refusing it unless it defines an `:id`
  of its own is the shape that mistake surfaces in.

  ## Capabilities

  `activation/1` and `versioning/1` answer what a resource declared. Neither
  sniffs for a column: `:active` and `:version` are both names another extension
  may own for its own reasons, so a declaration is the only thing either one
  reads.

  What hangs off each answer differs. Activation is read at render time —
  `inactive?/1` dims a row, and the QuickView asks before offering an
  activate/deactivate action — so its readers here are on the hot path. The
  optimistic lock is instead wired at compile time by
  `AshQuick.Versioning.Transformer`, which hands the resolved attribute to the
  change directly; `versioning?/1` and `versioning_attribute/1` are for code
  outside AshQuick that has to ask.

  ## Bookkeeping

  `bookkeeping/1` answers which of `created_at`, `updated_at`, `created_by` and
  `updated_by` a resource carries, and `timestamp_fields/1`, `actor_fields/1`
  and `actor_attributes/1` are the list forms a caller iterates.
  `created_at_field/1` and its three siblings read one key at a time, for a
  caller whose two sides go missing independently — the details header renders
  "created" and "last updated" as separate halves, and an append-only resource
  has only the first.

  Unlike the two above, these read as an *inventory* rather than a switch:
  `AshQuick.Bookkeeping.Verifier` holds the declaration and the resource's real
  fields to each other at compile time, so an answer here is a fact about the
  resource and not a claim it made. That is what lets
  `AshQuick.Config.versioning_ignored_attributes/1` be derived from it —
  a resource whose declaration had drifted would bump its optimistic lock on
  writes that used to be no-ops, and the verifier is what makes that
  unreachable.
  """

  alias AshQuick.Bookkeeping.Declaration
  alias AshQuick.Lookup.Declaration, as: LookupDeclaration

  @doc """
  The field a record of `resource` is labelled by.

  Always a field the resource defines — a resource that resolves to none does
  not compile — so a caller building a query has one field to select or load
  and rendering has one field to read.

  Raises for a resource without the extension. That is a wiring mistake, not a
  runtime condition: a QuickView refuses one at compile time, and the
  relationship destinations a QuickView names are for the host to pin with a
  test of its own.
  """
  def display_label(resource) do
    declared_label(resource) ||
      raise ArgumentError, """
      #{inspect(resource)} does not carry the AshQuick extension, so nothing has \
      resolved what one of its records is called.

      Add it to the resource:

          use Ash.Resource,
            extensions: [AshQuick, ...]
      """
  end

  @doc """
  The label for `record`, or `nil` when its label field holds nothing
  renderable.

  A query has to have materialized the field — `AshQuick.LiveView.Utils.load_display_label/1`
  is what the dropdown, details and print queries use for that.

  Rendering stays total where `display_label/1` is strict: anything with no
  label to read — a `Money`, an embedded value, a resource without the
  extension — is `nil` here, so a caller shows the id rather than raising
  mid-render. `nil` is also what a label field holding `nil`, an
  `Ash.NotLoaded` or an `Ash.ForbiddenField` gives back, which is why those
  callers reach for the id through `Map.get/2`: the fallback fires on records
  that were never guaranteed to carry one.
  """
  def display_value(%resource{} = record) do
    case declared_label(resource) do
      nil -> nil
      label -> record |> Map.get(label) |> to_label()
    end
  end

  def display_value(_record), do: nil

  @doc """
  The read action a search over `resource` runs through.

  One action stands behind the list page, the export and every relationship
  dropdown pointing at this resource, so all three ask here rather than
  spelling `:index` themselves. A QuickView's `list: [default_action: ...]`
  overrides it for that one page's list.

  Raises for a resource without the extension — a wiring mistake rather than a
  runtime condition, and the same one `display_label/1` refuses.
  """
  def lookup_action(resource), do: lookup_option(resource, &LookupDeclaration.action/1)

  @doc """
  The argument `lookup_action/1` takes the user's search text as.

  Callers pass `nil` when there is nothing to search for, which is what an
  action's preparation matches on to leave the query unfiltered.
  """
  def lookup_search_argument(resource),
    do: lookup_option(resource, &LookupDeclaration.search_argument/1)

  @doc """
  What `resource` declared under `ash_quick do activation do ... end end`, or
  `nil` when it declared nothing.

  Returns the resolved `:attribute`, `:activate_action` and `:deactivate_action`
  so a caller reads names rather than assuming them.

  A resource can carry an `:active` column without carrying activation — an
  extension that switches its own records on and off may define one for its
  own purposes. Sniffing the column would filter those out of a dropdown, so every
  behaviour AshQuick hangs on activation asks here instead.
  """
  def activation(resource) do
    if enabled?(resource) do
      %{
        attribute: get_activation(resource, :attribute, :active),
        activate_action: get_activation(resource, :activate_action, :activate),
        deactivate_action: get_activation(resource, :deactivate_action, :deactivate)
      }
    end
  end

  @doc """
  Whether `resource` declared activation.
  """
  def activation?(resource), do: not is_nil(activation(resource))

  @doc """
  Whether `record` is currently deactivated — `false` for a resource that
  declared no activation.

  A record whose attribute holds `nil` counts as inactive, matching the column's
  nullability.
  """
  def inactive?(%resource{} = record) do
    case activation(resource) do
      nil -> false
      %{attribute: attribute} -> !Map.get(record, attribute)
    end
  end

  def inactive?(_record), do: false

  @doc """
  What `resource` declared under `ash_quick do versioning do ... end end`, or
  `nil` when it is off — or when the resource does not carry the extension at
  all, since nothing declared it and no transformer ran.

  Returns the resolved `:attribute` so a caller reads the name rather than
  assuming `:version`.

  Unlike activation this is **on by default**, so the extension check is what
  keeps a resource without it from reading as versioned: a bare
  `Spark.Dsl.Extension.get_opt/4` would hand back the `true` default for any
  module at all.
  """
  def versioning(resource) do
    if versioning_enabled?(resource) do
      %{attribute: AshQuick.Versioning.Declaration.attribute(resource)}
    end
  end

  @doc """
  Whether writes to `resource` are guarded by an optimistic lock.
  """
  def versioning?(resource), do: not is_nil(versioning(resource))

  @doc """
  The attribute `resource` locks on, or `nil` when it carries no lock.

  Where a caller reads the counter from — the name is the resource's to choose,
  so nothing outside the declaration should spell `:version`.
  """
  def versioning_attribute(resource) do
    case versioning(resource) do
      nil -> nil
      %{attribute: attribute} -> attribute
    end
  end

  @doc """
  What `resource` declared under `ash_quick do bookkeeping do ... end end`, or
  `nil` when it does not carry the extension.

  A map of all four keys — `:created_at`, `:updated_at`, `:created_by`,
  `:updated_by` — each holding the field's name or `nil` where the resource
  declared it absent. Every key is always present, so a caller matches on the
  value rather than on the shape.

  All four default on, and `AshQuick.Bookkeeping.Verifier` refuses to compile a
  resource whose declaration disagrees with its fields in either direction. So
  this is not what a resource *says* it has — it is what it has, and everything
  below can be derived from it without a second look at the resource.
  """
  def bookkeeping(resource) do
    if declared?(resource) do
      Map.new(
        Declaration.timestamps() ++ Declaration.actors(),
        &{&1, Declaration.field(resource, &1)}
      )
    end
  end

  @doc """
  The timestamp attributes `resource` carries, in declaration order — `[]` for a
  resource carrying neither or without the extension.
  """
  def timestamp_fields(resource), do: fields(resource, Declaration.timestamps())

  @doc """
  The actor **relationships** `resource` stamps, in declaration order.

  Relationship names, which is what `Ash.Changeset`'s `relationships` map is
  keyed by. For the columns behind them, see `actor_attributes/1`.
  """
  def actor_fields(resource), do: fields(resource, Declaration.actors())

  @doc """
  The source attributes behind `actor_fields/1` — the `:created_by_id` /
  `:updated_by_id` end of each relationship.

  Read off the relationship rather than built from its name, so a `belongs_to`
  declared `define_attribute? false` over a hand-written column resolves to that
  column. A user resource that hand-writes its `updated_by_id` column and
  declares the relationship over it is exactly that shape, and a
  `:"\#{name}_id"` guess would work there only by coincidence.
  """
  def actor_attributes(resource) do
    resource
    |> actor_fields()
    |> Enum.map(&Ash.Resource.Info.relationship(resource, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.map(& &1.source_attribute)
  end

  @doc """
  The attribute holding when a record was created, or `nil`.
  """
  def created_at_field(resource), do: bookkeeping_field(resource, :created_at)

  @doc """
  The attribute holding when a record was last written, or `nil`.
  """
  def updated_at_field(resource), do: bookkeeping_field(resource, :updated_at)

  @doc """
  The relationship to the actor that created a record, or `nil`.
  """
  def created_by_field(resource), do: bookkeeping_field(resource, :created_by)

  @doc """
  The relationship to the actor that last wrote a record, or `nil`.
  """
  def updated_by_field(resource), do: bookkeeping_field(resource, :updated_by)

  defp bookkeeping_field(resource, key) do
    case bookkeeping(resource) do
      nil -> nil
      declared -> Map.fetch!(declared, key)
    end
  end

  defp fields(resource, keys) do
    case bookkeeping(resource) do
      nil -> []
      declared -> keys |> Enum.map(&Map.fetch!(declared, &1)) |> Enum.reject(&is_nil/1)
    end
  end

  # Spark hands back a section's defaults for any module at all, so without this
  # every module in the app would read as carrying all four fields.
  defp declared?(resource) do
    Ash.Resource.Info.resource?(resource) and AshQuick in Spark.extensions(resource)
  end

  defp versioning_enabled?(resource) do
    Ash.Resource.Info.resource?(resource) and
      AshQuick in Spark.extensions(resource) and
      AshQuick.Versioning.Declaration.enabled?(resource)
  end

  defp enabled?(resource) do
    Ash.Resource.Info.resource?(resource) and
      get_activation(resource, :enabled?, false)
  end

  defp get_activation(resource, option, default) do
    Spark.Dsl.Extension.get_opt(resource, [:ash_quick, :activation], option, default)
  end

  # The default is carried by `AshQuick.Lookup.Declaration` rather than read
  # back from the schema: Spark hands back nothing for a section the resource
  # never entered, so a resource following the convention silently declares
  # nothing at all. The extension is what is actually checked here — a resource
  # carrying it has an answer either way, and one without it was never asked.
  defp lookup_option(resource, reader) do
    if Ash.Resource.Info.resource?(resource) and AshQuick in Spark.extensions(resource) do
      reader.(resource)
    else
      raise ArgumentError, """
      #{inspect(resource)} does not carry the AshQuick extension, so nothing has \
      declared which of its actions a search runs through.

      Add it to the resource:

          use Ash.Resource,
            extensions: [AshQuick, ...]
      """
    end
  end

  # `nil` for anything the transformer never ran on — a struct that is not a
  # resource at all, or a resource without the extension.
  defp declared_label(resource) do
    if Ash.Resource.Info.resource?(resource) do
      Spark.Dsl.Extension.get_opt(resource, [:ash_quick, :display], :label, nil)
    end
  end

  # A field the query never materialized is `nil`, so a caller shows the
  # record's id rather than a `#Ash.NotLoaded<...>` inspect or a raise
  # mid-render. Everything else is whatever the value prints as, so a label
  # declared on a ci_string, decimal or date renders rather than silently
  # degrading to the id.
  defp to_label(nil), do: nil
  defp to_label(%Ash.NotLoaded{}), do: nil
  defp to_label(%Ash.ForbiddenField{}), do: nil
  defp to_label(value) when is_binary(value), do: value
  defp to_label(value) when is_number(value) or is_atom(value), do: to_string(value)

  defp to_label(%_{} = value) do
    if String.Chars.impl_for(value), do: to_string(value)
  end

  defp to_label(_value), do: nil
end
