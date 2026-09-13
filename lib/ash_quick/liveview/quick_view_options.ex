defmodule AshQuick.LiveView.QuickView.Options do
  @moduledoc false
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
    print_templates: [],
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
    bulk_actions: [type: {:fun, 1}]
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
            print_templates: [type: {:list, :atom}],
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
      print_templates: opts[:print_templates] || [],
      sidebar: opts[:sidebar],
      export_fields: normalize_fields(opts[:export_fields] || list_opts[:fields], default_attrs)
    }
    |> put_list_options(list_opts, default_attrs)
    |> put_details_options(details_opts, default_attrs)
    |> put_form_options(opts[:form] || [])
    |> validate_lookups!()
  end

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
  # or a `many_to_many` behind an `_ids` argument.
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
  # sound rather than merely convenient. Every create and update action is
  # walked because a QuickView reaches any of them through `?action=`.
  #
  # A field carrying a configured widget is skipped: `FormView.field_input/1`
  # matches the widget clause before the relationship ones, so that field
  # renders no dropdown and its destination is never searched. Demanding a
  # lookup action of it would refuse to compile a page over a search that
  # cannot happen.
  defp dropdown_destinations(%__MODULE__{resource: resource} = options) do
    for action <- Ash.Resource.Info.actions(resource),
        action.type in [:create, :update],
        field <- Utils.action_fields(resource, action.name),
        not is_nil(field),
        not Map.has_key?(options.form_widgets, field.name),
        destination = destination(field, resource),
        not is_nil(destination),
        uniq: true do
      destination
    end
  end

  defp destination(field, resource) do
    case Utils.argument_to_relationship(field, resource) do
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
