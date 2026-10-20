defmodule AshQuick.LiveView.QuickView.Options do
  @moduledoc false
  alias AshQuick.LiveView.EnumOptions
  alias AshQuick.LiveView.QuickField
  alias AshQuick.LiveView.Utils
  alias AshQuick.Lookup.Contract
  alias Ash.Resource.Relationships.BelongsTo
  alias Ash.Resource.Relationships.ManyToMany

  @enforce_keys [:module, :resource, :domain]

  defstruct [
    :module,
    :resource,
    :domain,
    :base_filter,
    :sort_by,
    :new_action_label,
    :bulk_actions,
    load: [],
    liveness_options: [],
    filters: %{},
    sidebar: true,
    list_fields: [],
    list_load: [],
    list_default_action: :index,
    details_fields: [],
    details_load: [],
    details_default_action: :read,
    details_featured_actions: [:update, :destroy],
    export_fields: [],
    form_widgets: %{}
  ]

  @rel_path_type {:list, {:tuple, [:atom, {:or, [:atom, {:list, {:tuple, [:atom, :atom]}}]}]}}
  @field_type {:or,
               [
                 :atom,
                 @rel_path_type,
                 {:tuple, [:atom, :string]},
                 {:tuple, [:atom, :keyword_list]},
                 {:tuple, [@rel_path_type, :string]},
                 {:tuple, [@rel_path_type, :keyword_list]}
               ]}
  @fields_type {:list, @field_type}
  @load_type {:list, {:or, [:atom, {:tuple, [:atom, :any]}]}}

  @liveness_schema [
    recursive?: [type: :boolean],
    extra_records: [type: {:fun, 1}],
    subscribe: [type: {:fun, 1}],
    refetch_window: [type: :non_neg_integer],
    pub_sub: [type: :atom]
  ]

  @list_schema [
    fields: [type: @fields_type],
    load: [type: @load_type],
    default_action: [type: :atom],
    new_action_label: [type: :string],
    bulk_actions: [type: {:or, [{:list, :any}, {:fun, 1}]}]
  ]

  @form_schema [
    widgets: [type: {:map, :atom, {:fun, 1}}]
  ]

  @details_schema [
    fields: [type: @fields_type],
    load: [type: @load_type],
    default_action: [type: :atom],
    featured_actions: [type: {:list, :atom}]
  ]

  @schema NimbleOptions.new!(
            resource: [type: :atom, required: true],
            sort_by: [type: :keyword_list],
            load: [type: @load_type],
            base_filter: [type: :any],
            sidebar: [type: :boolean, default: true],
            liveness_options: [type: :keyword_list, keys: @liveness_schema],
            filters: [type: {:list, {:map, :string, :any}}],
            export_fields: [type: @fields_type],
            list: [type: :keyword_list, keys: @list_schema],
            details: [type: :keyword_list, keys: @details_schema],
            form: [type: :keyword_list, keys: @form_schema]
          )

  def new(module, resource, opts) do
    opts = NimbleOptions.validate!(opts, @schema)
    validate_extension!(module, resource)
    default_attrs = Ash.Resource.Info.attribute_names(resource)
    list_opts = opts[:list] || []
    details_opts = opts[:details] || []

    %__MODULE__{
      module: module,
      resource: resource,
      domain: Ash.Resource.Info.domain(resource),
      base_filter: opts[:base_filter],
      sort_by: opts[:sort_by],
      load: opts[:load] || [],
      liveness_options: opts[:liveness_options] || [],
      filters: opts[:filters] || %{},
      sidebar: opts[:sidebar],
      export_fields: normalize_fields(opts[:export_fields] || list_opts[:fields], default_attrs)
    }
    |> put_list_options(list_opts, default_attrs)
    |> put_details_options(details_opts, default_attrs)
    |> put_form_options(opts[:form] || [])
    |> validate_lookups!()
    |> validate_list_inputs!()
    |> validate_bulk_actions!()
  end

  # A function's list is only known once there is a socket to call it with, and
  # `AshQuick.LiveView.BulkActions.menu/2` checks it then.
  defp validate_bulk_actions!(%__MODULE__{bulk_actions: items} = options) when is_list(items) do
    AshQuick.LiveView.BulkActions.check!(items, options.resource, options.module)
    options
  end

  defp validate_bulk_actions!(options), do: options

  # Everything a QuickView asks of a resource it was not written against —
  # what a record is called, which fields a role may see, how a change reaches
  # the page — is answered by the extension's transformers. A resource without
  # it compiles fine and then answers those questions with silence: a label of
  # `:id`, no publications, no notifier. The page looks healthy and is not, so
  # the requirement is stated here rather than discovered.
  defp validate_extension!(module, resource) do
    if AshQuick not in Spark.extensions(resource) do
      raise ArgumentError, """
      #{inspect(module)} is a QuickView over #{inspect(resource)}, which does not \
      carry the AshQuick extension.

      Add it to the resource:

          use Ash.Resource,
            extensions: [AshQuick, ...]
      """
    end
  end

  # Absence is the half `AshQuick.Lookup.Verifier` deliberately cannot catch.
  # Whether a resource needs a lookup action is not a fact about the resource —
  # it depends on something pointing at it — so the demand is made here, where
  # what points at what is known, and a resource nothing lists or selects from
  # is never asked.
  #
  # Two kinds of reader are checked. The list action, which this page reads its
  # own rows and its export through; and every resource a dropdown on one of
  # this page's forms would search, which is a `belongs_to` this page can edit
  # or a `many_to_many` an argument edits.
  defp validate_lookups!(%__MODULE__{} = options) do
    Contract.check!(
      options.resource,
      options.list_default_action,
      "#{inspect(options.module)} lists #{inspect(options.resource)} through an action AshQuick cannot search."
    )

    Enum.each(dropdown_destinations(options), fn destination ->
      Contract.check!(
        destination,
        "#{inspect(options.module)} renders a dropdown onto #{inspect(destination)}, which AshQuick cannot search."
      )
    end)

    options
  end

  # `Utils.action_fields/2` without a scope is the superset the scope-filtered
  # form can render — field restrictions only ever narrow it — so checking it is
  # sound rather than merely convenient. Every public create and update action
  # is walked because a QuickView reaches any of them through `?action=`, and a
  # private one never.
  #
  # A field carrying a configured widget is skipped: `FormView.field_input/1`
  # matches the widget clause before the relationship ones, so that field
  # renders no dropdown and its destination is never searched. Demanding a
  # lookup action of it would refuse to compile a page over a search that
  # cannot happen.
  defp dropdown_destinations(%__MODULE__{resource: resource} = options) do
    for {action, field} <- form_fields(options, [:create, :update]),
        destination = destination(field, resource, action),
        not is_nil(destination),
        uniq: true do
      destination
    end
  end

  # The fields this page's built-in inputs render on the public actions of
  # `types`: a field a widget renders is the host's, and is never asked about.
  defp form_fields(%__MODULE__{resource: resource} = options, types) do
    for action <- Ash.Resource.Info.public_actions(resource),
        action.type in types,
        field <- Utils.action_fields(resource, action.name),
        not is_nil(field),
        not Map.has_key?(options.form_widgets, field.name),
        do: {action, field}
  end

  # A form gives a list with no fixed set of values its generic text input
  # (`FormView.field_input/1`'s last clause), which posts one string the list
  # refuses: nothing on the form can save it, and an update form over a record
  # already holding values cannot render them. Refused here rather than on the
  # resource, because only the page knows which fields a widget renders.
  #
  # Every public create, update and destroy is walked, as for the dropdowns
  # above: a QuickView reaches any of them through `?action=` or the modal.
  defp validate_list_inputs!(%__MODULE__{resource: resource} = options) do
    unsaveable =
      for {action, field} <- form_fields(options, [:create, :update, :destroy]),
          unsaveable_list?(field, resource, action),
          do: {action.name, field}

    if unsaveable != [] do
      raise ArgumentError, """
      #{inspect(options.module)}'s forms would offer #{inspect(resource)} lists \
      they cannot save:

      #{Enum.map_join(unsaveable, "\n", fn {action, field} -> "  * #{inspect(action)} takes #{inspect(field.name)}, #{inspect(field.type)}" end)}

      A list with no fixed set of values to pick from gets a text input, which \
      posts one string the list refuses. For each, name the values it may hold \
      and it is picked from a select:

          constraints: [items: [one_of: [:a, :b]]]

      or type its items with an `Ash.Type.Enum`, render it with a form widget \
      that posts a list:

          form: [widgets: %{#{elem(hd(unsaveable), 1).name}: &__MODULE__.#{elem(hd(unsaveable), 1).name}_input/1}]

      or leave it out of the action. A field restriction that hides it does not \
      count: whether it hides the field depends on who opens the form, and the \
      page is checked for anyone.
      """
    end

    options
  end

  # The item types that reach the generic text input. An allowlist rather than
  # "anything no other clause takes": embeds, unions and managed relationships
  # get sub-forms from AshPhoenix, which is only known once a form is built.
  # An id list argument is left out too: it is a relationship dropdown, or
  # renders nothing at all.
  @text_items [
    Ash.Type.String,
    Ash.Type.CiString,
    Ash.Type.Atom,
    Ash.Type.Module,
    Ash.Type.Integer,
    Ash.Type.Float,
    Ash.Type.Decimal,
    Ash.Type.Boolean,
    Ash.Type.Date,
    Ash.Type.Time,
    Ash.Type.TimeUsec,
    Ash.Type.DateTime,
    Ash.Type.UtcDatetime,
    Ash.Type.UtcDatetimeUsec,
    Ash.Type.NaiveDatetime,
    Ash.Type.Duration,
    Ash.Type.UUID,
    Ash.Type.UUIDv7,
    Ash.Type.Binary,
    Ash.Type.UrlEncodedBinary,
    AshQuick.AshTypes.Text
  ]

  # Untyped items, which a text input cannot save either, unless the action
  # manages a relationship through the argument: AshPhoenix then builds a
  # sub-form for each.
  @untyped_items [Ash.Type.Map, Ash.Type.Keyword, Ash.Type.Term]

  defp unsaveable_list?(%Ash.Resource.Actions.Argument{type: {:array, item}}, _resource, _action)
       when item in [Ash.Type.UUID, Ash.Type.UUIDv7],
       do: false

  defp unsaveable_list?(%{type: {:array, item}} = field, resource, action) do
    cond do
      not is_nil(EnumOptions.kind(field)) -> false
      text_item?(item) -> true
      untyped_item?(item) -> not Utils.managed_argument?(field, resource, action)
      true -> false
    end
  end

  defp unsaveable_list?(_field, _resource, _action), do: false

  defp untyped_item?(item) when item in @untyped_items, do: true

  defp untyped_item?(item) when is_atom(item) do
    Ash.Type.NewType.new_type?(item) and untyped_item?(Ash.Type.NewType.subtype_of(item))
  end

  defp untyped_item?(_item), do: false

  defp text_item?(item) when item in @text_items, do: true

  defp text_item?(item) when is_atom(item) do
    Ash.Type.NewType.new_type?(item) and text_item?(Ash.Type.NewType.subtype_of(item))
  end

  defp text_item?(_item), do: false

  defp destination(field, resource, action) do
    case Utils.argument_to_relationship(field, resource, action) do
      %BelongsTo{destination: destination} -> destination
      %ManyToMany{destination: destination} -> destination
      _ -> nil
    end
  end

  defp put_list_options(options, list_opts, default_attrs) do
    %{
      options
      | list_fields: normalize_fields(list_opts[:fields], default_attrs),
        list_load: list_opts[:load] || [],
        list_default_action:
          list_opts[:default_action] || AshQuick.Info.lookup_action(options.resource),
        new_action_label: list_opts[:new_action_label],
        bulk_actions: list_opts[:bulk_actions]
    }
  end

  defp put_details_options(options, details_opts, default_attrs) do
    %{
      options
      | details_fields: normalize_fields(details_opts[:fields], default_attrs),
        details_load: details_opts[:load] || [],
        details_default_action: details_opts[:default_action] || :read,
        details_featured_actions: details_opts[:featured_actions] || [:update, :destroy]
    }
  end

  # Forms have no configurable field list — `Utils.action_fields/2` derives them
  # from the action — so a form widget is keyed by field name rather than
  # declared alongside a field the way list/details widgets are.
  defp put_form_options(options, form_opts) do
    %{options | form_widgets: form_opts[:widgets] || %{}}
  end

  defp normalize_fields(fields, default_attrs) do
    (fields || default_attrs)
    |> Enum.map(&QuickField.normalize/1)
  end
end
