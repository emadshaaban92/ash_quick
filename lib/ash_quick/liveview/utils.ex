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

  defp titleize(name) do
    name
    |> Phoenix.Naming.humanize()
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  # Only a create, update or destroy offers fields. A form can still be built
  # for a read: AshPhoenix builds a sub-form for one where a relationship looks
  # its records up (`on_lookup`), and the page draws none of it.
  def action_fields(resource, action_name) do
    case Ash.Resource.Info.action(resource, action_name) do
      %{type: type} = action when type in [:create, :update, :destroy] ->
        accepted_fields(resource, action)

      _no_fields ->
        []
    end
  end

  defp accepted_fields(resource, action) do
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

  @doc """
  The relationship an id-list argument of `action` edits, or the argument
  itself when it edits none.

  The argument edits the relationship a `manage_relationship` change on the
  action (or, failing that, a global one covering it) names it for, whatever
  it is called. A change's `where:` is not consulted: it is judged against the
  changeset on submit, so the form takes the change at its word.
  With no such change, an argument named `<relationship>_ids` is still taken
  to edit `<relationship>`.
  """
  def argument_to_relationship(%Argument{type: {:array, item_type}} = arg, resource, action)
      when item_type in [Ash.Type.UUID, Ash.Type.UUIDv7] do
    case managed_relationship(resource, action, arg.name) || ids_relationship(arg.name) do
      nil -> arg
      name -> Ash.Resource.Info.relationship(resource, name) || arg
    end
  end

  def argument_to_relationship(arg, _resource, _action), do: arg

  @doc """
  Whether `action` manages a relationship through `field`, an argument, so that
  AshPhoenix builds a sub-form for each item rather than one input for the list.
  """
  def managed_argument?(%Argument{name: name}, resource, action),
    do: not is_nil(managed_relationship(resource, action, name))

  def managed_argument?(_field, _resource, _action), do: false

  @doc """
  Whether `resource`'s `action_name` is a public action, which is all a page
  may offer: see `record_actions/1` for why a private one is never reachable.
  """
  def public_action?(resource, action_name),
    do: match?(%{public?: true}, Ash.Resource.Info.action(resource, action_name))

  # `action_changes/2` puts global changes first; the action's own change is the
  # more specific statement, so it is the one looked at first.
  defp managed_relationship(resource, action, argument) do
    resource
    |> Ash.Resource.Info.action_changes(action)
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Ash.Resource.Change{change: {Ash.Resource.Change.ManageRelationship, opts}} ->
        if opts[:argument] == argument, do: opts[:relationship]

      _ ->
        nil
    end)
  end

  defp ids_relationship(argument) do
    name = to_string(argument)
    if String.ends_with?(name, "_ids"), do: String.trim_trailing(name, "_ids")
  end

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

  @doc """
  Materializes the resource's display hint on `query`, when it declares one.

  Merged into the select rather than strict, so it adds the hint beside the
  label without narrowing whatever the caller selected.
  """
  def load_display_hint(%Ash.Query{resource: resource, tenant: tenant} = query) do
    Ash.Query.load(query, hint_fields(resource, tenant))
  end

  @doc """
  What a load names to bring `resource`'s display hint: `[hint]`, or `[]`
  when it declares none.

  Also `[]` for an aggregate hint over a resource that needs a tenant, when
  `tenant` is nil: loading it would fail the whole read rather than drop one
  hint, which is the rule `load_fields/3` applies to an aggregate field.
  Every hint load asks here, so that rule holds wherever a hint is loaded.
  """
  def hint_fields(resource, tenant) do
    case AshQuick.Info.display_hint(resource) do
      nil -> []
      hint -> if loadable?(resource, hint, tenant), do: [hint], else: []
    end
  end

  defp loadable?(_resource, _field, tenant) when not is_nil(tenant), do: true

  defp loadable?(resource, field, nil) do
    case Ash.Resource.Info.field(resource, field) do
      %Ash.Resource.Aggregate{relationship_path: path} -> not require_tenant?(resource, path)
      _ -> true
    end
  end

  @doc """
  A relationship dropdown's option for `record`, submitted as its `key`.

  LiveSelect tells a picked option from the others by its `label`, so the
  label carries the hint, "Name (hint)", the way a hinted link's accessible
  name does: two records sharing a name are then two options it can tell
  apart, and the closed single-select and a tag LiveSelect restores after a
  reconnect still show which record it is. `:name` and `:hint` are the two
  parts, for the slots that draw them separately. Falls back to the key when
  there is no label, since that still points at the record picked.
  """
  def to_option(record, key) do
    value = Map.fetch!(record, key)
    name = AshQuick.Info.display_value(record) || to_string(value)
    hint = AshQuick.Info.display_hint_value(record)

    %{
      label: AshQuick.LiveView.Components.FieldValue.label_with_hint(name, hint),
      value: value,
      name: name,
      hint: hint
    }
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
  The actions a page may take on a record of `resource`: its public updates,
  then its public destroys.

  An action declared `public?: false` is the host's own. Ash's documentation
  says no extension may expose one, and the policy it recommends for them,
  `bypass private_action?() do authorize_if always() end`, lets every call to
  one through. Offered here, it would be an action anyone holding the page can
  run with no policy asking who they are.
  """
  def record_actions(resource) do
    actions = Ash.Resource.Info.public_actions(resource)

    Enum.filter(actions, &(&1.type == :update)) ++ Enum.filter(actions, &(&1.type == :destroy))
  end

  @doc """
  The action out of `actions` that a client event names, or `nil`.

  An event carries whatever the browser sent, so the name is matched against
  what the page could have offered rather than looked up on the resource. A name
  that matches nothing is refused here instead of reaching `Ash.Resource.Info`,
  where it would find a private action, a read or a create just as readily.
  """
  def offered_action(actions, name) when is_binary(name) do
    Enum.find(actions, &(Atom.to_string(&1.name) == name))
  end

  def offered_action(_actions, _name), do: nil

  @doc """
  `fields` without the ones a field policy hides from `scope` on every record
  `action` reads.

  A field whose policy depends on the record stays, since the actor sees it on
  some rows, and Ash marks the rest with `Ash.ForbiddenField`; `opts` go to
  `Ash.can_see_fields/4`, whose `filter_is: false` drops it too, keeping only
  the fields the actor sees on every record. Only a field of
  `resource` itself is asked about: a relationship path is judged by the related
  resource's policies, record by record, in the same way.

  The answer only shapes the page. Ash has already replaced what the actor may
  not read, so a check that fails keeps every field rather than failing the
  page.
  """
  def visible_fields(fields, resource, action, scope, opts \\ []) do
    policed =
      resource
      |> Ash.Resource.Info.fields([:attributes, :calculations, :aggregates])
      |> MapSet.new(& &1.name)

    names = fields |> Enum.map(&field_path/1) |> Enum.filter(&MapSet.member?(policed, &1))

    case names do
      [] ->
        fields

      names ->
        case Ash.can_see_fields({resource, action.name}, scope, Enum.uniq(names), opts) do
          {:ok, visible} -> Enum.reject(fields, &(Map.get(visible, field_path(&1)) == false))
          {:error, _error} -> fields
        end
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
