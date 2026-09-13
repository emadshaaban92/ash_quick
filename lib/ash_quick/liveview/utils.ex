defmodule AshQuick.LiveView.Utils do
  @moduledoc false
  require Ash.Query

  alias Ash.Resource.Actions.Argument
  alias Ash.Resource.Relationships

  @relationships [
    Relationships.BelongsTo,
    Relationships.HasOne,
    Relationships.HasMany,
    Relationships.ManyToMany
  ]

  @humanize_overrides Application.compile_env(:ash_quick, :humanize_overrides, [])

  for {key, label} <- @humanize_overrides do
    str_key = Atom.to_string(key)
    def humanize(unquote(str_key)), do: unquote(label)
    def humanize(unquote(key)), do: unquote(label)
  end

  def humanize("destroy"), do: "Delete"

  def humanize(name) when is_atom(name), do: humanize(Atom.to_string(name))

  def humanize(name) when is_binary(name) do
    if String.ends_with?(name, "_ar") do
      "#{titleize(String.trim_trailing(name, "_ar"))} (Arabic)"
    else
      titleize(name)
    end
  end

  @doc """
  Formats a `Money` for display, rendering an em dash for a missing amount.
  """
  def format_money(%Money{} = money) do
    case Money.to_string(money) do
      {:ok, string} -> string
      _ -> "—"
    end
  end

  def format_money(_), do: "—"

  defp titleize(name) do
    name
    |> Phoenix.Naming.humanize()
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def action_fields(resource, action_name) do
    action = Ash.Resource.Info.action(resource, action_name)
    attributes = Ash.Resource.Info.attributes(resource)
    relationships = Ash.Resource.Info.relationships(resource)

    action.accept
    |> Enum.map(fn attr_name ->
      Enum.find(relationships, &(&1.source_attribute == attr_name)) ||
        Enum.find(attributes, &(&1.name == attr_name))
    end)
    |> Enum.concat(action.arguments)
  end

  def action_fields(resource, action_name, scope) do
    check_context = scope_to_check_context(scope)

    resource
    |> action_fields(action_name)
    |> Enum.filter(fn field ->
      AshQuick.FieldRestrictions.Info.field_visible?(
        resource,
        action_name,
        field.name,
        check_context
      )
    end)
  end

  defp scope_to_check_context(scope) do
    %AshQuick.FieldRestrictions.Check.Context{
      actor: scope_to_actor(scope),
      tenant: scope_to_tenant(scope)
    }
  end

  defp scope_to_actor(scope) do
    case Ash.Scope.ToOpts.get_actor(scope) do
      {:ok, actor} -> actor
      _ -> nil
    end
  end

  defp scope_to_tenant(scope) do
    case Ash.Scope.ToOpts.get_tenant(scope) do
      {:ok, tenant} -> tenant
      _ -> nil
    end
  end

  def argument_to_relationship(%Argument{type: {:array, item_type}, name: name} = arg, resource)
      when item_type in [Ash.Type.UUID, Ash.Type.UUIDv7] do
    relationship =
      if String.ends_with?(name |> to_string(), "_ids") do
        relation_name = String.trim_trailing(name |> to_string(), "_ids")
        Ash.Resource.Info.relationship(resource, relation_name)
      end

    relationship || arg
  end

  def argument_to_relationship(arg, _resource), do: arg

  @doc """
  The action input a search over `resource` is read with.

  The argument's name is the resource's to choose, so nothing outside
  `AshQuick.Info.lookup_search_argument/1` spells `:search` — the list, the
  export and both relationship dropdowns all build their input here.

  The two callers disagree about what "nothing typed" is — the list carries
  `""` for an empty box (`AshQuick.LiveView.URLParams`) and a dropdown opens on
  `nil` — and nothing here reconciles them, because `Ash.Type.String` already
  does: `allow_empty?` defaults to false, so an empty string casts to `nil`
  before any preparation sees it. Both therefore arrive as the `nil` every
  preparation matches to leave the query unfiltered.
  """
  def lookup_input(resource, search) do
    %{AshQuick.Info.lookup_search_argument(resource) => search}
  end

  @doc """
  The checked lookup action behind a relationship dropdown.

  `AshQuick.LiveView.QuickView.Options` holds every dropdown a QuickView
  renders from its own resource's create and update actions to the lookup
  contract while that QuickView compiles. A dropdown placed by hand reaches no
  such check: `BelongsToInput` and `HasManyInput` are plain live components, so
  a template outside a QuickView — a bespoke LiveView, a layout — can point one
  at any destination it likes and nothing at compile time walks a `.heex` to
  find it.

  The same contract is therefore asked here, at the open, which is the first
  moment the destination is known. The failure is the one that would have
  happened anyway — `Ash.Query.for_read/4` on a missing action, or
  `require_arguments/2` on an unsearched read — carrying the relationship that
  led here and the fix instead of the raw Ash error.
  """
  def lookup_action!(relationship) do
    AshQuick.Lookup.Contract.check!(
      relationship.destination,
      "A dropdown onto #{inspect(relationship.source)}.#{relationship.name} " <>
        "searches #{inspect(relationship.destination)}, which AshQuick cannot search."
    )
  end

  @doc """
  Materializes the resource's display label on `query`.

  One `load` covers every kind of label the resource can carry: an attribute is
  selected, a calculation or aggregate loaded. Callers that only render the
  label narrow the select themselves first.
  """
  def load_display_label(%Ash.Query{resource: resource} = query) do
    Ash.Query.load(query, AshQuick.Info.display_label(resource), strict?: true)
  end

  def load_fields(query, fields, opts \\ [])

  def load_fields(%Ash.Query{} = query, [], _opts), do: query

  def load_fields(%Ash.Query{} = query, [%AshQuick.LiveView.QuickField{path: path} | rest], opts) do
    load_fields(query, [path | rest], opts)
  end

  def load_fields(%Ash.Query{} = query, [{field, _field_opts} | rest], opts) do
    query
    |> load_fields([field | rest], opts)
  end

  def load_fields(%Ash.Query{} = query, [field_name | rest], opts) when is_atom(field_name) do
    query
    |> maybe_load_field(field_name, opts)
    |> load_fields(rest, opts)
  end

  def load_fields(%Ash.Query{} = query, [field | rest], opts) do
    query
    |> Ash.Query.load(field, opts)
    |> load_fields(rest, opts)
  end

  defp maybe_load_field(query, field_name, opts) when is_atom(field_name) do
    field = query.resource |> Ash.Resource.Info.field(field_name)

    case field do
      nil ->
        query
        |> Ash.Query.add_error(
          "Field #{field_name} not found in resource #{query.resource}. Please check your configuration."
        )

      _ ->
        maybe_load_field(query, field, opts)
    end
  end

  # A field that stops at a relationship renders as the destination's display
  # label, so the label is named rather than left to the plain load: that one
  # brings every attribute of the destination only while nothing else has
  # narrowed its select, and an attribute label would silently go missing when
  # something had. The nested load is deliberately not `strict?` for the
  # opposite reason — the same relationship is usually also listed under an
  # explicit path, and narrowing its select here would drop whatever that reads.
  defp maybe_load_field(query, %struct{name: name, destination: destination}, opts)
       when struct in @relationships do
    query
    |> Ash.Query.load(name, opts)
    |> Ash.Query.load([{name, AshQuick.Info.display_label(destination)}])
  end

  defp maybe_load_field(%{tenant: tenant} = query, %{name: field_name}, opts)
       when not is_nil(tenant) do
    Ash.Query.load(query, field_name, opts)
  end

  defp maybe_load_field(query, %Ash.Resource.Aggregate{name: field_name} = field, opts) do
    if require_tenant?(query.resource, field.relationship_path) do
      query
    else
      Ash.Query.load(query, field_name, opts)
    end
  end

  defp maybe_load_field(query, %{name: field_name}, opts) do
    Ash.Query.load(query, field_name, opts)
  end

  defp require_tenant?(_resource, []), do: false

  defp require_tenant?(resource, [rel | rest]) do
    relationship = Ash.Resource.Info.relationship(resource, rel)

    case Ash.Resource.Info.multitenancy_attribute(relationship.destination) do
      nil -> require_tenant?(relationship.destination, rest)
      _ -> not Ash.Resource.Info.multitenancy_global?(relationship.destination)
    end
  end

  def field_label(%AshQuick.LiveView.QuickField{label: label}), do: label
  def field_label(field) when is_atom(field), do: humanize(field)
  def field_label({_, label}) when is_binary(label), do: label
  def field_label({field, _}) when is_atom(field), do: humanize(field)
  def field_label([field]), do: field_label(field)

  @doc """
  Withholds `query`'s inactive records, for a resource that declared activation.

  A resource carrying an `:active` column it never declared keeps every record:
  the column is another extension's, and filtering on it would drop rows the
  actor is entitled to pick.

  The predicate is AshQuick's own, not the actor's, so it is pinned rather than
  parsed as input — a declared attribute that happens to be private still
  filters instead of failing the read.
  """
  def filter_inactive(%Ash.Query{resource: resource} = query) do
    case AshQuick.Info.activation(resource) do
      nil -> query
      %{attribute: attribute} -> Ash.Query.filter(query, ^Ash.Expr.ref(attribute) == true)
    end
  end

  @doc """
  Drops the activation action `record` is already in the state of — `:activate`
  from an active record, `:deactivate` from an inactive one — so a page offers
  only the transition that means something.

  Both actions survive for a resource that declared no activation, which has no
  state here to judge them against.
  """
  def reject_redundant_activation(actions, %resource{} = record) do
    case AshQuick.Info.activation(resource) do
      nil ->
        actions

      %{attribute: attribute, activate_action: activate, deactivate_action: deactivate} ->
        active = Map.get(record, attribute)

        actions
        |> Stream.reject(&(&1.name == activate && active))
        |> Stream.reject(&(&1.name == deactivate && active == false))
    end
  end

  def field_path(%AshQuick.LiveView.QuickField{path: path}), do: path
  def field_path({field, label}) when is_binary(label), do: field
  def field_path([field]), do: field_path(field)
  def field_path(field), do: field
end
