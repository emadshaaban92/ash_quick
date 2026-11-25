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

  def humanize("destroy"), do: "Delete"

  def humanize(name) when is_atom(name), do: humanize(Atom.to_string(name))

  def humanize(name) when is_binary(name) do
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
      AshQuick.ReadOnlyFields.Info.writable?(
        resource,
        action_name,
        field.name,
        check_context
      )
    end)
  end

  @doc """
  The fields an `AshPhoenix.Form` handles: `action_fields/2` for its action,
  without those a field policy hides on the record it updates.

  Ash reads such a field back as `%Ash.ForbiddenField{}`. An input cannot
  draw one, a sub-form cannot be built over one, and a field drawn empty
  would save that emptiness over a value its reader never saw. So the form
  leaves the field out everywhere, drawing, uploads and embeds alike, and the
  save leaves it as it is. A field a policy hides on some records only is left
  out of the forms for those records. An argument named like a hidden field is
  left out too: the form prefills it from that field.

  Every path of a form that walks its fields walks this list, so none of them
  meets a hidden value. `form_fields/2` is the same list less the fields
  `read_only_fields` keeps the actor from writing, which is what the form
  draws.
  """
  def form_fields(%{resource: resource, action: action} = form) do
    resource
    |> action_fields(action)
    |> reject_hidden(Map.get(form, :data))
  end

  def form_fields(%{resource: resource, action: action} = form, scope) do
    resource
    |> action_fields(action, scope)
    |> reject_hidden(Map.get(form, :data))
  end

  @doc """
  The names of the fields `record` holds as `%Ash.ForbiddenField{}`: those a
  field policy hides from whoever read it.
  """
  def hidden_field_names(%_{} = record) do
    for {name, %Ash.ForbiddenField{}} <- Map.from_struct(record), do: name
  end

  def hidden_field_names(_data), do: []

  @doc """
  The nested forms `AshPhoenix.Form` would build for `action` on its own,
  without those under `hidden`: passed as `forms:`, they keep a sub-form from
  being built over a value the reader may not see.
  """
  def nested_forms(resource, action, hidden) do
    resource
    |> AshPhoenix.Form.Auto.auto(action)
    |> Keyword.drop(hidden)
    |> Keyword.put(:auto?, false)
  end

  @doc """
  The relationships an update form for `action` must find loaded on its
  record: each one a `manage_relationship` change edits through sub-forms that
  are built over the related records (its `on_match` updates or destroys
  them, or reads them), and, under each, those its own sub-forms edit in turn.

  `AshPhoenix.Form` reads such a relationship off the record, and draws no
  sub-form for one left unloaded. Its rows would then post nothing, and a
  change that destroys what it is not sent, such as `direct_control`, would
  destroy every stored row on a plain save. A relationship already on the
  path is not walked again, so a change that manages its way back stops there.

  Each relationship names its destination's attributes selected by default,
  beside its own nested loads: merged with a host's `load:` that narrows the
  same relationship's select, it widens it again, so a sub-form never draws
  an attribute empty and saves that emptiness over the stored value.
  """
  def managed_loads(resource, action) do
    resource
    |> AshPhoenix.Form.Auto.auto(action)
    |> managed_loads_of(MapSet.new())
  end

  defp managed_loads_of(forms, seen) do
    for {_key, opts} <- forms,
        {source, name, _manage_opts} <- [opts[:managed_relationship]],
        not MapSet.member?(seen, {source, name}),
        opts = built_form_opts(opts),
        Keyword.has_key?(opts, :data) do
      %{destination: destination} = Ash.Resource.Info.relationship(source, name)

      {name,
       Enum.to_list(Ash.Resource.Info.selected_by_default_attribute_names(destination)) ++
         managed_loads_of(opts[:forms] || [], MapSet.put(seen, {source, name}))}
    end
  end

  defp built_form_opts(opts) do
    case opts[:updater] do
      updater when is_function(updater, 1) -> updater.(opts)
      _ -> opts
    end
  end

  defp reject_hidden(fields, data) do
    case hidden_field_names(data) do
      [] -> fields
      hidden -> Enum.reject(fields, &hidden?(&1, hidden))
    end
  end

  defp hidden?(%Relationships.BelongsTo{} = field, hidden),
    do: field.name in hidden or field.source_attribute in hidden

  defp hidden?(field, hidden), do: field.name in hidden

  defp scope_to_check_context(scope) do
    %AshQuick.ReadOnlyFields.Check.Context{
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
  The relationship a list argument of `action` edits, or the argument itself
  when it edits none.

  An id list edits the relationship a `manage_relationship` change on the
  action (or, failing that, a global one covering it) names it for, whatever
  it is called. A change's `where:` is not consulted: it is judged against the
  changeset on submit, so the form takes the change at its word.
  With no such change, an argument named `<relationship>_ids` is still taken
  to edit `<relationship>`.

  A list of text edits a many_to_many only through such a change that names
  `value_is_key` and looks the values up (`on_lookup`): each item is then a
  value of that destination attribute, which `list_key/3` names.
  """
  def argument_to_relationship(%Argument{type: {:array, item_type}} = arg, resource, action)
      when item_type in [Ash.Type.UUID, Ash.Type.UUIDv7] do
    case managed_relationship(resource, action, arg.name) || ids_relationship(arg.name) do
      nil -> arg
      name -> Ash.Resource.Info.relationship(resource, name) || arg
    end
  end

  def argument_to_relationship(%Argument{type: {:array, item_type}} = arg, resource, action) do
    with true <- text_type?(item_type),
         change when is_list(change) <- managed_change(resource, action, arg.name),
         key when is_atom(key) and not is_nil(key) <- change[:opts][:value_is_key],
         %Relationships.ManyToMany{} = relationship <-
           Ash.Resource.Info.relationship(resource, change[:relationship]),
         true <-
           Ash.Changeset.ManagedRelationshipHelpers.could_lookup?(
             manage_opts(relationship, change)
           ) do
      relationship
    else
      _ -> arg
    end
  end

  def argument_to_relationship(arg, _resource, _action), do: arg

  @doc """
  The destination attribute each item of `argument`, a list editing
  `relationship` (`argument_to_relationship/3`), is a value of: the change's
  `value_is_key`, else the destination's primary key. A composite key has no
  single value to post, so it is refused, naming the relationship.
  """
  def list_key(%Argument{name: name}, relationship, action) do
    change = managed_change(relationship.source, action, name) || []

    case change[:opts][:value_is_key] ||
           Ash.Resource.Info.primary_key(relationship.destination) do
      key when is_atom(key) ->
        key

      [key] ->
        key

      keys ->
        raise ArgumentError, """
        #{inspect(relationship.destination)} has the composite primary key \
        #{inspect(keys)}, which a multi-select has no single value to submit for. \
        #{inspect(relationship.source)}.#{relationship.name} cannot be edited \
        through a list argument unless its manage_relationship names value_is_key.
        """
    end
  end

  @doc """
  How a picker over `argument`, a list of text editing `relationship`, may
  add values that match no record: `%{action: create, match: :exact |
  :any_case, read_action: read}`, or `nil` when it may not. `read_action`
  is the destination read the change looks typed values up through: its
  own `read_action`, else the primary read.

  It may when the action's `manage_relationship` change creates what it
  finds no match for (`on_no_match: :create` or `{:create, action}`, as Ash
  resolves it) and that create accepts the `value_is_key` attribute, which
  is all a typed value can fill. A `ci_string` key matches in any case, as
  the lookup will. Whether the actor may run the create is asked where the
  scope is known.
  """
  def created_values(%Argument{name: name, type: {:array, item_type}}, relationship, action) do
    with true <- text_type?(item_type),
         change when is_list(change) <- managed_change(relationship.source, action, name),
         key when is_atom(key) and not is_nil(key) <- change[:opts][:value_is_key],
         opts = manage_opts(relationship, change),
         {:create, create, _join_create, _join_keys} <- opts[:on_no_match],
         %{accept: accept} <- Ash.Resource.Info.action(relationship.destination, create),
         true <- key in accept do
      attribute = Ash.Resource.Info.attribute(relationship.destination, key)

      %{
        action: create,
        match: if(ci_string?(attribute), do: :any_case, else: :exact),
        read_action:
          opts[:read_action] ||
            Ash.Resource.Info.primary_action!(relationship.destination, :read).name
      }
    else
      _ -> nil
    end
  end

  def created_values(_argument, _relationship, _action), do: nil

  # The options as the change will run them: its `type`'s defaults under
  # what it says, resolved by Ash as `manage_relationship` resolves them.
  defp manage_opts(relationship, change) do
    opts = change[:opts] || []
    defaults = if opts[:type], do: Ash.Changeset.manage_relationship_opts(opts[:type]), else: []

    Ash.Changeset.ManagedRelationshipHelpers.sanitize_opts(
      relationship,
      Keyword.merge(defaults, opts)
    )
  end

  defp text_type?(type), do: base_type(type) in [Ash.Type.String, Ash.Type.CiString]

  defp ci_string?(%{type: type}), do: base_type(type) == Ash.Type.CiString
  defp ci_string?(_attribute), do: false

  defp base_type(type) do
    type = Ash.Type.get_type(type)

    if is_atom(type) and Ash.Type.NewType.new_type?(type),
      do: base_type(Ash.Type.NewType.subtype_of(type)),
      else: type
  end

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
    case managed_change(resource, action, argument) do
      nil -> nil
      change -> change[:relationship]
    end
  end

  # The options of the `manage_relationship` change through `argument`.
  defp managed_change(resource, action, argument) do
    resource
    |> Ash.Resource.Info.action_changes(action)
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Ash.Resource.Change{change: {Ash.Resource.Change.ManageRelationship, opts}} ->
        if opts[:argument] == argument, do: opts

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

  Loads what `label_fields/2` names for the query's tenant, so an aggregate
  label the reader's tenant cannot count is left unloaded rather than failing
  the read; `AshQuick.Info.display_value/1` then reads `nil` and the caller
  falls back to the id.
  """
  def load_display_label(%Ash.Query{resource: resource, tenant: tenant} = query) do
    Ash.Query.load(query, label_fields(resource, tenant), strict?: true)
  end

  @doc """
  What a load names to bring `resource`'s display label: `[label]`.

  `[]` for an aggregate label over a resource that needs a tenant, when
  `tenant` is nil: loading it would fail the whole read rather than drop one
  label, which is the rule `load_fields/3` applies to an aggregate field and
  `hint_fields/2` to a hint. Every label load asks here — a list's rows, a
  details record and its writers, a dropdown's options, the record a field
  links and a print — so that rule holds wherever a label is loaded.
  """
  def label_fields(resource, tenant) do
    label = AshQuick.Info.display_label(resource)
    if loadable?(resource, label, tenant), do: [label], else: []
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

  `:name` is the record's display label and `:hint` its display hint, for the
  picker to draw separately. Falls back to the key when there is no label,
  since that still points at the record picked.
  """
  def to_option(record, key) do
    value = Map.fetch!(record, key)
    name = AshQuick.Info.display_value(record) || to_string(value)
    hint = AshQuick.Info.display_hint_value(record)

    %{
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

  def load_fields(%Ash.Query{} = query, [[{name, _nested}] = path | rest], opts)
      when is_atom(name) do
    {load, labels} = path_loads(query.resource, path, query.tenant)

    query
    |> Ash.Query.load(load, opts)
    |> Ash.Query.load(labels || [])
    |> load_fields(rest, opts)
  end

  def load_fields(%Ash.Query{} = query, [field | rest], opts) do
    query
    |> Ash.Query.load(field, opts)
    |> load_fields(rest, opts)
  end

  # A path through relationships (`[bin: :item_count]`,
  # `[packing: [box: :bin]]`) loaded by the rule its last field would be
  # loaded by at the top: an aggregate needing a tenant the query has not got
  # is left out, though the relationships reaching it are still loaded, so the
  # record it would have named is still there to link; and a path stopping at a
  # relationship brings the destination's label too. Returns the path's load,
  # and the label load beside it, or `nil` — merged rather than strict, for the
  # reason `maybe_load_field/3` gives.
  defp path_loads(resource, [{name, nested}], tenant) when is_atom(name) do
    case Ash.Resource.Info.relationship(resource, name) do
      %{destination: destination} ->
        {load, labels} = path_loads(destination, nested, tenant)
        {[{name, load}], labels && [{name, labels}]}

      # Not a relationship: loaded as written, so Ash says what is wrong.
      nil ->
        {[{name, nested}], nil}
    end
  end

  defp path_loads(resource, name, tenant) when is_atom(name) do
    case Ash.Resource.Info.field(resource, name) do
      %struct{destination: destination} when struct in @relationships ->
        {name, [{name, record_fields(destination, tenant)}]}

      _field ->
        if loadable?(resource, name, tenant), do: {name, nil}, else: {[], nil}
    end
  end

  defp path_loads(_resource, nested, _tenant), do: {nested, nil}

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
    |> Ash.Query.load([{name, record_fields(destination, query.tenant)}])
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

  # What a field stopping at a relationship renders the record from: the
  # record as a plain load brings it, every attribute selected by default,
  # and its label. The attributes are named rather than left to that load,
  # because a strict load brings them only while nothing else has narrowed the
  # destination's select: a field listed earlier reaching one field of the same
  # record (`[bin: :item_count]` before `:bin`) would otherwise leave a widget
  # handed the record with `NotLoaded` attributes. Merged, so it widens the
  # select and never narrows it.
  defp record_fields(destination, tenant) do
    Enum.to_list(Ash.Resource.Info.selected_by_default_attribute_names(destination)) ++
      label_fields(destination, tenant)
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
