defmodule AshQuick.FormState do
  @moduledoc """
  What a QuickView form shows, and how: its fields, in the order they are
  drawn, each with its label, help text and whether it is hidden, disabled or
  required.

  AshQuick builds it from the form every time the form changes and hands it to
  the QuickView's `adjust_form/2` callback, which returns it changed. The page
  draws the form from what comes back, and the server takes what the person
  posted through it, so a field the hook hides is neither drawn nor taken.

      defmodule MyAppWeb.OrderLive.Quick do
        use AshQuick.LiveView.QuickView, resource: MyApp.Sales.Order

        alias AshQuick.FormState

        defp adjust_form(%{action: %{name: action}} = state, _options)
             when action in [:create, :update] do
          discount? = FormState.value(state, :kind) == :discount

          state
          |> FormState.hide(:discount_reason, not discount?)
          |> FormState.require(:discount_reason, discount?)
        end

        defp adjust_form(state, _options), do: state
      end

  ## Rebuilt every time

  The state is built again from the form on every event and goes through the
  hook every time. Nothing a hook did on one event is remembered on the next,
  so the hook states the whole rule each time, from the values it reads with
  `value/2`. A rule must never be skipped: a field a hook leaves out of one
  pass is shown again on that event, and its params are taken. This is what
  keeps it right after a reconnect, when the form is built again from what
  the page still shows.

  It is built when the form opens (`stage: :build`), on each change, an
  upload, a sub-form added or removed and an attachment removed
  (`:validate`), and when the form is saved (`:submit`). A save refused with
  errors on its fields builds it again under `:validate`.

  ## Narrow only

  The fields are the ones the form would draw without a hook: the action's
  inputs, less those a field policy hides on the record and those
  `read_only_fields` keeps the actor from writing. The functions here can
  hide, disable, require and relabel them. They cannot add a field, bring back
  one Ash left out, or make a field Ash requires optional. Whatever a hook
  returns, only these flags are taken from it.

  So which fields are in the state depends on the actor. A function named
  with an input of the action that this actor's form leaves out does
  nothing, and `value/2` answers nil for it, so one hook serves every role.
  A name that is no input of the action at all raises an `ArgumentError`
  listing the form's fields: it is a mistake in the hook.

  ## What the server does with it

  At every change and at the save, the server builds the state from the
  params that were just posted, runs the hook and drops the params of every
  hidden or disabled field before Ash sees them. It does not trust the page
  it drew last, so a hand-made post cannot pair a hidden field with the value
  that hides it. On an update, a hidden or disabled field keeps the record's
  value. At the save, a field `require/3` marks that is blank gets a field
  error, and the action does not run. An error Ash files under a hidden or
  disabled field has no input to show under, so it is flashed.

  The hook runs for QuickView forms only. Bulk forms, the API and code calling
  the action never run it, so a rule that has to hold whatever the caller
  belongs in the resource. Hiding a field does not clear it: on an update it
  keeps the record's value. So a value that must not outlive the kind that
  shows it is cleared by a change, not refused by a validation, which a form
  that hides the field could never get past:

      change set_attribute(:discount_reason, nil),
        where: [attribute_does_not_equal(:kind, :discount)]

      validate present(:discount_reason),
        where: [attribute_equals(:kind, :discount)]

  Use the hook for what the person sees.

  ## Guard on the action

  The hook runs for every form the QuickView opens, a destroy's too, whose
  form takes no inputs. A function named with a field the action does not
  take raises, so a hook that names fields matches the actions that take
  them, as above, and passes any other state through.

  ## Keep it cheap

  The hook runs on every change, and at the save. A read in it runs on every
  keystroke that posts, so keep reads out of it, or cheap: there is no way to
  skip one on an event, since every event states every rule again. A picker
  narrowed by `lookup_args/3` or `filter/3` reads only when the person opens
  it, or when what narrows it changes.

  ## Drawing

  `visible_fields/1` is what the form draws. A disabled field is drawn as its
  value, read-only, the way the details page shows it. A widget
  (`form: [widgets: ...]`) is given its field's entry as `@state_field`, and
  a custom `action_*` template the whole state as `@ash_quick_form_state`, so
  either can follow the flags; the server strips and enforces them whatever a
  template draws.

  ## Picker filters and options

  A picker of records (a `belongs_to`, or a list argument over a
  many-to-many) can be narrowed with `filter/3`, an Ash filter on top of the
  relationship's own `filter`s, and `lookup_args/3`, arguments passed to the
  destination's lookup action. A field picked from a fixed set (an
  `Ash.Type.Enum`, or an atom with `one_of`) is narrowed with `options/3`:

      import Ash.Expr

      country = FormState.value(state, :country)

      state
      |> FormState.lookup_args(:city, %{country_id: country})
      |> FormState.filter(:stop_ids, expr(country_id == ^country))
      |> FormState.options(:status, [:draft, :submitted])

  `lookup_args/3` keeps the rule in the destination resource, behind its
  policies, and is what a lookup action taking the argument wants. A picker
  searches again only when its filter or arguments change: as the rest of
  the form changes, it is not read again.

  When a change narrows a picker past what it holds, the pick is kept, under
  its own label: it is not cleared behind the person's back. The save then
  refuses it with an error under the field. A hook that wants it cleared
  clears it itself. At the save, the records a field holds are read back
  through the query its picker searches, the lookup action with the field's
  arguments, the relationship's filters and the field's, one read per field,
  and a key the read does not find is refused, as is an inactive record. A
  value outside `options/3` is refused the same way.

  This also holds a pick to the relationship's own `filter`s when the hook
  narrows nothing. A field drawn by a widget or a type's form input
  (`AshQuick.FormInput`) offers what its input offers, so the save reads it back
  only when the hook narrows it. A key an update's record already holds is not
  read back then: the save leaves it as it is. When the hook narrows the field,
  that key is read back too, since the rule that narrows it may have changed,
  and so is an enum value the record holds outside `options/3`. A record the
  reader may not read, which the picker shows as unavailable, is not found by
  that read either, so the save is refused until another is picked. To keep what
  the record holds whatever it is, `disable/3` the field.

  ## Sub-forms

  A field drawn as sub-forms (an embed, or a relationship the action manages)
  holds a state of its own for each of its sub-forms, built from that
  sub-form as the root's is from the root form: `state.forms` maps the
  field's name to its rows' states, in the order they are drawn (a single
  sub-form is a list of one). `update_each/3` states a rule once for every
  row, and a row reads its parent's values through `state.parent`:

      state
      |> FormState.update_each([:lines], fn line ->
        line
        |> FormState.hide(:serial, FormState.value(line, :kind) != :device)
        |> FormState.require(:serial, FormState.value(line, :kind) == :device)
        |> FormState.disable(:discount, FormState.value(line.parent, :channel) != :wholesale)
      end)

  A path names one field per level, `[:lines, :parts]` for the parts of every
  line. Rows are built again from the sub-forms on every event, so a row
  removed or added never leaves a rule on the wrong row: there is no index
  to go stale.

  The server holds a sub-form's fields to its state as it does the root's: a
  hidden or disabled field's params are dropped from that row, a row's
  required field left blank refuses the save with an error under it, and on
  a row the record already holds, a hidden or disabled field keeps the row's
  value. The fields of a sub-form under a hidden or disabled field are not
  looked at: the whole field keeps the record's value, or is left out.

  Which stored row a posted row is, AshPhoenix decides: the one with the
  same primary key when the row posts all of it, as a related record's row
  does, and otherwise the one at the same place, as for an embed, which has
  no key. So a rule that hides or disables a field on embed rows keeps, for
  each row, the value of the stored row at its place. The page's own Add and
  ✕ never move rows in a post. A template that draws AshPhoenix's `_drop_`
  or `_sort_` inputs does, and so does a reconnect after a stored row was
  removed: the rows after it then keep the value of the stored row above.
  Where each row must keep its own, give the embedded resource a public
  primary key (`uuid_primary_key :id, public?: true`): its rows then post
  it, and each is matched to its own stored row wherever it ends up.
  """

  alias Ash.Resource.Relationships.BelongsTo
  alias AshQuick.FormState.Field
  alias AshQuick.Labels
  alias AshQuick.LiveView.EnumOptions
  alias AshQuick.LiveView.Utils

  @type stage :: :build | :validate | :submit

  @type t :: %__MODULE__{
          stage: stage(),
          resource: module(),
          action: struct(),
          record: struct() | nil,
          scope: term(),
          form: AshPhoenix.Form.t(),
          fields: [Field.t()],
          forms: %{optional(atom()) => [t()]},
          parent: t() | nil
        }

  @enforce_keys [:stage, :resource, :action, :form, :fields]
  defstruct [:stage, :resource, :action, :record, :scope, :form, :parent, fields: [], forms: %{}]

  @doc """
  The value the form holds for the field `name`, cast by Ash: an atom for an
  enum, a `Decimal` for a decimal, the id for a `belongs_to`. A value that
  does not cast is the posted value as it came.

  A hidden or disabled field holds the value it has without its params: the
  record's on an update, the default on a create. An input of the action
  that this actor's form leaves out answers nil.
  """
  @spec value(t(), atom()) :: term()
  def value(%__MODULE__{} = state, name) do
    case fetch(state, name) do
      %Field{} = field -> input_value(state.form, field)
      nil -> nil
    end
  end

  @doc "The entry for the field `name`, or nil when the form has no such field."
  @spec field(t(), atom()) :: Field.t() | nil
  def field(%__MODULE__{fields: fields}, name), do: Enum.find(fields, &(&1.name == name))

  @doc """
  Hides the field `name` when `condition` is true: it is not drawn, and its
  params are dropped.
  """
  @spec hide(t(), atom(), boolean()) :: t()
  def hide(state, name, condition \\ true)
  def hide(state, name, true), do: update!(state, name, &%{&1 | hidden?: true})
  def hide(state, name, false), do: tap(state, &fetch(&1, name))

  @doc """
  Undoes a `hide/3`. A field Ash leaves out of this actor's form is not in
  the state, so there is nothing to show, and nothing happens.
  """
  @spec show(t(), atom()) :: t()
  def show(state, name), do: update!(state, name, &%{&1 | hidden?: false})

  @doc """
  Marks the field `name` required when `condition` is true. The input says
  so, and the save refuses a blank value with an error under it.

  A field Ash already requires stays required either way.
  """
  @spec require(t(), atom(), boolean()) :: t()
  def require(state, name, condition \\ true)
  def require(state, name, true), do: update!(state, name, &%{&1 | required?: true})
  def require(state, name, false), do: tap(state, &fetch(&1, name))

  @doc """
  Disables the field `name` when `condition` is true: it shows its value,
  read-only, and its params are dropped as a hidden field's are.
  """
  @spec disable(t(), atom(), boolean()) :: t()
  def disable(state, name, condition \\ true)
  def disable(state, name, true), do: update!(state, name, &%{&1 | disabled?: true})
  def disable(state, name, false), do: tap(state, &fetch(&1, name))

  @doc "Draws the field `name` with `label`."
  @spec put_label(t(), atom(), String.t()) :: t()
  def put_label(state, name, label) when is_binary(label),
    do: update!(state, name, &%{&1 | label: label})

  @doc "Draws the field `name` with `help` under it, or none when nil."
  @spec put_help(t(), atom(), String.t() | nil) :: t()
  def put_help(state, name, help) when is_binary(help) or is_nil(help),
    do: update!(state, name, &%{&1 | help: help})

  @doc """
  Adds HTML attributes to the input of the field `name`, such as a
  `placeholder`. A plain input takes them (a text, number, date, time,
  password or long text input), and so do the money amount box and a type's
  input from `config :ash_quick, form_inputs:` (`AshQuick.FormInput`). They
  are meant for extra attributes: the input already sets its own `id`,
  `name`, `class` and `aria-*`, and the browser keeps the first of two.
  """
  @spec put_attrs(t(), atom(), keyword()) :: t()
  def put_attrs(state, name, attrs) when is_list(attrs),
    do: update!(state, name, &%{&1 | attrs: Keyword.merge(&1.attrs, attrs)})

  @doc """
  Adds `filter`, an Ash filter expression over the destination, to the
  records the picker of the field `name` offers: a `belongs_to`, or a list
  argument over a many-to-many. It goes on top of the relationship's own
  `filter`s and the lookup action, and each call adds one more.

      import Ash.Expr

      country = FormState.value(state, :country)
      FormState.filter(state, :city, expr(country_id == ^country))

  At the save, the records the field holds are read back through the same
  query, and one it leaves out gets an error under the field: see "Picker
  filters and options" in the moduledoc. A field drawn by a widget gets the
  error too, which the widget shows itself.

  The picker searches again whenever the filter differs from the one it
  searched with, compared by value: a filter pinning a value that changes
  on every run, such as `^DateTime.utc_now()`, searches again on every
  change to the form. Pin a value that holds still, such as the date.

  A field that picks no records raises an `ArgumentError`, and so does one
  whose destination has no lookup action to read through.
  """
  @spec filter(t(), atom(), term()) :: t()
  def filter(state, name, filter) do
    picker!(state, name, "filter/3")
    update!(state, name, &%{&1 | filters: &1.filters ++ [filter]})
  end

  @doc """
  Passes `args`, a map of arguments, to the lookup action the picker of the
  field `name` reads its records through, as `filter/3` narrows them. Each
  call merges into what earlier calls passed. The search the person types
  is the lookup action's own argument, and wins over one named here.

      FormState.lookup_args(state, :city, %{country_id: FormState.value(state, :country)})

  This keeps the rule in the destination resource, and its policies: the
  lookup action decides what the argument means. At the save, the records
  the field holds are read back with the same arguments.

  An argument the lookup action does not take, or a field that picks no
  records, raises an `ArgumentError`.
  """
  @spec lookup_args(t(), atom(), map()) :: t()
  def lookup_args(state, name, args) when is_map(args) do
    case fetch(state, name) do
      %Field{} = field ->
        relationship = picker!(state, name, "lookup_args/3")
        check_lookup_args!(relationship, args, state, field)
        update!(state, name, &%{&1 | lookup_args: Map.merge(&1.lookup_args, args)})

      nil ->
        state
    end
  end

  @doc """
  Narrows the values the field `name` offers, one picked from a fixed set (an
  `Ash.Type.Enum`, or an atom with `one_of`, alone or in a list), to
  `values`, drawn in the order the type lists them. A second call narrows
  what the first left.

      FormState.options(state, :status, [:draft, :submitted])

  At the save, a value outside them gets an error under the field.

  A value the type does not list, or a field picked from no fixed set,
  raises an `ArgumentError`.
  """
  @spec options(t(), atom(), [term()]) :: t()
  def options(state, name, values) when is_list(values) do
    case fetch(state, name) do
      %Field{} = field ->
        offered = choice_values!(state, field)
        listed = MapSet.new(offered, &to_string/1)
        given = MapSet.new(values, &to_string/1)

        case Enum.reject(values, &MapSet.member?(listed, to_string(&1))) do
          [] ->
            :ok

          unknown ->
            raise ArgumentError,
                  "#{inspect(name)} of #{inspect(state.resource)}.#{state.action.name} " <>
                    "offers no #{inspect(unknown)}; its values are #{inspect(offered)}"
        end

        update!(state, name, fn field ->
          kept = Enum.filter(field.options || offered, &MapSet.member?(given, to_string(&1)))
          %{field | options: kept}
        end)

      nil ->
        state
    end
  end

  @doc """
  Puts each sub-form state at `path` through `fun`, which returns it changed.

  `path` names a field drawn as sub-forms, then one of its sub-form's, and so
  on: `[:lines]` reaches every line, `[:lines, :parts]` every part of every
  line. `fun` is given each state with `parent` set to the state it is a
  sub-form of, as it stands when `update_each/3` is called, so it can read
  the parent's values with `value/2`.

  A field this actor's form leaves out does nothing. A name that is no input
  of the action raises an `ArgumentError`, and so does one that is not drawn
  as sub-forms.
  """
  @spec update_each(t(), [atom()], (t() -> t())) :: t()
  def update_each(%__MODULE__{} = state, [name | rest], fun) when is_function(fun, 1) do
    case fetch(state, name) do
      %Field{kind: :nested} ->
        parent = %{state | forms: %{}}

        rows =
          state.forms
          |> Map.get(name, [])
          |> Enum.map(&update_row(%{&1 | parent: parent}, rest, fun))

        %{state | forms: Map.put(state.forms, name, rows)}

      %Field{} ->
        raise_not_nested(state, name)

      nil ->
        state
    end
  end

  defp update_row(row, [], fun), do: apply_each(row, fun)
  defp update_row(row, rest, fun), do: update_each(row, rest, fun)

  defp apply_each(row, fun) do
    case fun.(row) do
      %__MODULE__{} = returned ->
        returned

      other ->
        raise ArgumentError,
              "the function given to update_each/3 must return an AshQuick.FormState, " <>
                "got: #{inspect(other)}"
    end
  end

  @doc """
  The sub-form states at `path`, in the order they are drawn, as
  `update_each/3` reaches them: `[:lines]` gives every line, `[:lines,
  :parts]` every part of every line. A field this actor's form leaves out
  gives none; a name that is no input of the action, or one not drawn as
  sub-forms, raises as `update_each/3` does.
  """
  @spec sub_forms(t(), [atom()]) :: [t()]
  def sub_forms(%__MODULE__{} = state, [name | rest]) do
    case fetch(state, name) do
      %Field{kind: :nested} ->
        rows = Map.get(state.forms, name, [])
        if rest == [], do: rows, else: Enum.flat_map(rows, &sub_forms(&1, rest))

      %Field{} ->
        raise_not_nested(state, name)

      nil ->
        []
    end
  end

  defp raise_not_nested(state, name) do
    raise ArgumentError,
          "#{inspect(name)} of #{inspect(state.resource)}.#{state.action.name} " <>
            "is not drawn as sub-forms"
  end

  @doc "The fields the form draws, in order: every field not hidden."
  @spec visible_fields(t()) :: [Field.t()]
  def visible_fields(%__MODULE__{fields: fields}), do: Enum.reject(fields, & &1.hidden?)

  # The field `name`, or nil when it is an input of the action this actor's
  # form leaves out. A name that is no input of the action raises.
  defp fetch(state, name) do
    cond do
      field = field(state, name) ->
        field

      input?(state, name) ->
        nil

      true ->
        raise ArgumentError,
              "the form of #{inspect(state.resource)}.#{state.action.name} has no field " <>
                "#{inspect(name)}; its fields are #{inspect(Enum.map(state.fields, & &1.name))}"
    end
  end

  defp input?(state, name) do
    state.resource
    |> Utils.action_fields(state.action.name)
    |> Enum.any?(&(&1.name == name))
  end

  defp update!(state, name, fun) do
    case fetch(state, name) do
      %Field{} ->
        %{
          state
          | fields: Enum.map(state.fields, &if(&1.name == name, do: fun.(&1), else: &1))
        }

      nil ->
        state
    end
  end

  # The relationship the field `name` picks records of, or a raise naming
  # `fun`. Nil when it is an input this actor's form leaves out.
  defp picker!(state, name, fun) do
    case fetch(state, name) do
      %Field{} = field ->
        relationship =
          relationship(state, field) ||
            raise ArgumentError,
                  "#{fun} narrows the records a picker offers, and #{inspect(name)} of " <>
                    "#{inspect(state.resource)}.#{state.action.name} picks no records"

        # The save reads the field's records back through the lookup action,
        # which a field a widget draws need not have: asked here, a missing
        # one fails in the hook, naming the fix.
        Utils.lookup_action!(relationship)
        relationship

      nil ->
        nil
    end
  end

  defp check_lookup_args!(relationship, args, state, field) do
    lookup = Utils.lookup_action!(relationship)
    action = Ash.Resource.Info.action(relationship.destination, lookup)
    taken = Enum.map(action.arguments, & &1.name)

    case Enum.reject(Map.keys(args), &(&1 in taken)) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "the lookup action #{inspect(relationship.destination)}.#{lookup} behind " <>
                "#{inspect(field.name)} of #{inspect(state.resource)}.#{state.action.name} " <>
                "takes no #{inspect(unknown)}; its arguments are #{inspect(taken)}"
    end
  end

  defp choice_values!(state, field) do
    if EnumOptions.kind(field.source) in [:single, :array] do
      field.source |> EnumOptions.values() |> List.wrap()
    else
      raise ArgumentError,
            "options/3 narrows a field picked from a fixed set, and #{inspect(field.name)} " <>
              "of #{inspect(state.resource)}.#{state.action.name} is not one"
    end
  end

  @doc false
  # The relationship whose records `field` picks: a `belongs_to`, or the
  # many-to-many a list argument edits. Nil for any other field.
  def relationship(_state, %Field{source: %BelongsTo{} = relationship}), do: relationship

  def relationship(state, %Field{source: %Ash.Resource.Actions.Argument{} = source}) do
    case Utils.argument_to_relationship(source, state.resource, state.action.name) do
      %Ash.Resource.Relationships.ManyToMany{} = relationship -> relationship
      _other -> nil
    end
  end

  def relationship(_state, _field), do: nil

  @doc false
  # Whether the hook narrows what `field` offers.
  def narrowed?(%Field{filters: filters, lookup_args: args, options: options}),
    do: filters != [] or args != %{} or options != nil

  # --- Built by AshQuick ---------------------------------------------------

  @doc false
  # The state of `form` before any hook: its fields as the form would draw
  # them.
  def new(form, stage, opts) do
    scope = opts[:scope]
    widgets = opts[:widgets] || %{}
    resource = form.resource
    action = Ash.Resource.Info.action(resource, form.action)

    fields =
      form
      |> Utils.form_fields(scope)
      |> Enum.map(&new_field(&1, form, widgets))

    state = %__MODULE__{
      stage: stage,
      resource: resource,
      action: action,
      record: if(form.type in [:update, :destroy], do: form.data),
      scope: scope,
      form: form,
      fields: fields,
      parent: opts[:parent]
    }

    # A sub-form has no widgets: they are named by the root's fields.
    sub_opts = [scope: scope, parent: state]

    forms =
      for %Field{kind: :nested, name: name} <- fields, into: %{} do
        rows =
          form.forms
          |> Map.get(name)
          |> List.wrap()
          |> Enum.map(&new(&1, stage, sub_opts))

        {name, rows}
      end

    %{state | forms: forms}
  end

  @doc false
  # Every sub-form state under `state`, a row before its own sub-forms, with
  # those under a hidden or disabled field left out: that whole field keeps
  # the record's value or is dropped, so its rows are not looked at.
  def taken_sub_forms(%__MODULE__{} = state) do
    for %Field{kind: :nested, hidden?: false, disabled?: false, name: name} <- state.fields,
        row <- Map.get(state.forms, name, []),
        state <- [row | taken_sub_forms(row)],
        do: state
  end

  @doc false
  # The state of the (sub-)form named `name` (`"form[lines][0]"`), or nil.
  def find(%__MODULE__{form: %{name: name}} = state, name), do: state

  def find(%__MODULE__{forms: forms}, name) do
    forms
    |> Map.values()
    |> List.flatten()
    |> Enum.find_value(&find(&1, name))
  end

  @doc false
  # What a hook returned, held to what AshQuick built: the same fields, in
  # the same order, with only the flags a hook may change taken from it. A
  # field Ash requires stays required.
  def narrow(%__MODULE__{} = built, %__MODULE__{} = returned) do
    by_name = Map.new(returned.fields, &{&1.name, &1})

    fields =
      Enum.map(built.fields, fn field ->
        case Map.fetch(by_name, field.name) do
          {:ok, %Field{} = got} -> narrow_field(field, got)
          _absent -> field
        end
      end)

    got_forms = if is_map(returned.forms), do: returned.forms, else: %{}

    forms =
      Map.new(built.forms, fn {name, rows} -> {name, narrow_rows(rows, got_forms[name])} end)

    %{built | fields: fields, forms: forms}
  end

  def narrow(%__MODULE__{}, returned) do
    raise ArgumentError,
          "adjust_form/2 must return an AshQuick.FormState, got: #{inspect(returned)}"
  end

  defp narrow_field(field, got) do
    %{
      field
      | hidden?: got.hidden? == true,
        disabled?: got.disabled? == true,
        required?: field.required? or got.required? == true,
        label: if(is_binary(got.label), do: got.label, else: field.label),
        help: if(is_binary(got.help) or is_nil(got.help), do: got.help, else: field.help),
        attrs: if(Keyword.keyword?(got.attrs), do: got.attrs, else: field.attrs),
        filters: if(is_list(got.filters), do: field.filters ++ got.filters, else: field.filters),
        lookup_args:
          if(is_map(got.lookup_args),
            do: Map.merge(got.lookup_args, field.lookup_args),
            else: field.lookup_args
          ),
        options: narrow_options(field, got.options)
    }
  end

  # Only values the type lists, in its order: a hook can narrow them, never
  # add one.
  defp narrow_options(field, options) when is_list(options) do
    if EnumOptions.kind(field.source) in [:single, :array],
      do: listed_options(field, options),
      else: field.options
  end

  defp narrow_options(field, _options), do: field.options

  defp listed_options(field, options) do
    given = MapSet.new(options, &to_string/1)

    field.source
    |> EnumOptions.values()
    |> List.wrap()
    |> Enum.filter(&MapSet.member?(given, to_string(&1)))
  end

  # Each row the form has, narrowed by the hook's row of the same sub-form,
  # found by its name. A row the hook dropped, or put something else in
  # place of, is kept as built.
  defp narrow_rows(rows, got) when is_list(got) do
    by_name = for %__MODULE__{form: %{name: name}} = row <- got, into: %{}, do: {name, row}

    Enum.map(rows, fn row ->
      case Map.fetch(by_name, row.form.name) do
        {:ok, got_row} -> narrow(row, got_row)
        :error -> row
      end
    end)
  end

  defp narrow_rows(rows, _got), do: rows

  @doc false
  # The params the server drops: every input of a hidden or disabled field,
  # with the `_unused_` marker Phoenix posts beside it.
  def dropped_params(%__MODULE__{fields: fields}) do
    for %Field{hidden?: h, disabled?: d, inputs: inputs} <- fields,
        h or d,
        input <- inputs,
        key = to_string(input),
        param <- [key, "_unused_" <> key],
        do: param
  end

  @doc false
  # The inputs of every hidden or disabled field, as param keys.
  def dropped_inputs(%__MODULE__{fields: fields}) do
    for %Field{hidden?: h, disabled?: d, inputs: inputs} <- fields,
        h or d,
        input <- inputs,
        do: to_string(input)
  end

  @doc false
  # The fields `require/3` marks that are drawn, writable and blank, which
  # Ash would not refuse on its own: a field it requires is its to refuse.
  def blank_required(%__MODULE__{} = state) do
    for %Field{required?: true, hidden?: false, disabled?: false} = field <- state.fields,
        not ash_required?(field.source),
        blank?(input_value(state.form, field)),
        do: field
  end

  defp blank?(value), do: value in [nil, "", []]

  defp input_value(form, %Field{source: source, inputs: [input | _]}) do
    changeset = form.source

    case source do
      %Ash.Resource.Actions.Argument{name: name} -> Ash.Changeset.get_argument(changeset, name)
      _attribute_or_relationship -> Ash.Changeset.get_attribute(changeset, input)
    end
  end

  defp new_field(source, form, widgets) do
    resource = form.resource

    %Field{
      name: source.name,
      inputs: inputs(source),
      kind: kind(source, form, widgets),
      label: label(source, form),
      help: Labels.help(source, resource, form.action),
      required?: shown_required?(source, form),
      source: source
    }
  end

  defp inputs(%BelongsTo{source_attribute: attribute}), do: [attribute]
  defp inputs(%{name: name}), do: [name]

  defp label(%Ash.Resource.Actions.Argument{} = source, form) do
    case many_to_many(source, form) do
      %{name: name} -> Labels.name(name, form.resource)
      nil -> Labels.name(source.name, form.resource)
    end
  end

  defp label(source, form), do: Labels.name(source.name, form.resource)

  # As the input says it: a secret an update keeps when left blank is not
  # asked for.
  defp shown_required?(%{sensitive?: true}, %{type: :update}), do: false
  defp shown_required?(source, _form), do: ash_required?(source)

  defp ash_required?(%{allow_nil?: allow_nil?}), do: not allow_nil?
  defp ash_required?(_source), do: false

  defp many_to_many(source, form) do
    case Utils.argument_to_relationship(source, form.resource, form.action) do
      %Ash.Resource.Relationships.ManyToMany{} = relationship -> relationship
      _ -> nil
    end
  end

  # The input `FormView` draws for the field, in the order it picks one.
  defp kind(source, form, widgets) do
    cond do
      is_function(Map.get(widgets, source.name)) -> :widget
      Map.get(source, :sensitive?) == true -> :password
      many_to_many(source, form) -> :many_to_many
      uuid_list_argument?(source) -> :text
      match?(%BelongsTo{}, source) -> :belongs_to
      EnumOptions.kind(source) in [:single, :array] -> :choice
      true -> typed_kind(source, form)
    end
  end

  @datetimes [Ash.Type.DateTime, Ash.Type.UtcDatetimeUsec, Ash.Type.UtcDatetime]

  defp typed_kind(%{type: type} = source, form) do
    cond do
      type == {:array, AshQuick.AshTypes.Attachment} -> :attachments
      type == AshQuick.AshTypes.Attachment -> :attachment
      type in @datetimes -> :datetime
      form.form_keys[source.name][:type] in [:list, :single] -> :nested
      type == AshQuick.AshTypes.Text -> :long_text
      type == Ash.Type.Boolean -> :boolean
      true -> plain_kind(source)
    end
  end

  defp uuid_list_argument?(%Ash.Resource.Actions.Argument{type: {:array, type}}),
    do: type in [Ash.Type.UUID, Ash.Type.UUIDv7]

  defp uuid_list_argument?(_source), do: false

  defp plain_kind(source) do
    case AshQuick.LiveView.FormInputs.attrs(source, nil)[:type] do
      "date" -> :date
      "time" -> :time
      "datetime-local" -> :naive_datetime
      _ -> if AshQuick.LiveView.FormInputs.number_kind(source), do: :number, else: :text
    end
  end
end
