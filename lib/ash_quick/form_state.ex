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
  skip one on an event, since every event states every rule again.

  ## Drawing

  `visible_fields/1` is what the form draws. A disabled field is drawn as its
  value, read-only, the way the details page shows it. A widget
  (`form: [widgets: ...]`) is given its field's entry as `@state_field`, and
  a custom `action_*` template the whole state as `@ash_quick_form_state`, so
  either can follow the flags; the server strips and enforces them whatever a
  template draws.

  Only the root form's fields are in the state: the fields of a sub-form are
  drawn as before.
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
          fields: [Field.t()]
        }

  @enforce_keys [:stage, :resource, :action, :form, :fields]
  defstruct [:stage, :resource, :action, :record, :scope, :form, fields: []]

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

    %__MODULE__{
      stage: stage,
      resource: resource,
      action: action,
      record: if(form.type in [:update, :destroy], do: form.data),
      scope: scope,
      form: form,
      fields: fields
    }
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
          {:ok, %Field{} = got} ->
            %{
              field
              | hidden?: got.hidden? == true,
                disabled?: got.disabled? == true,
                required?: field.required? or got.required? == true,
                label: if(is_binary(got.label), do: got.label, else: field.label),
                help: if(is_binary(got.help) or is_nil(got.help), do: got.help, else: field.help),
                attrs: if(Keyword.keyword?(got.attrs), do: got.attrs, else: field.attrs)
            }

          _absent ->
            field
        end
      end)

    %{built | fields: fields}
  end

  def narrow(%__MODULE__{}, returned) do
    raise ArgumentError,
          "adjust_form/2 must return an AshQuick.FormState, got: #{inspect(returned)}"
  end

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
      uuid_list_argument?(source) -> uuid_list_kind(source, form)
      match?(%BelongsTo{}, source) -> :belongs_to
      EnumOptions.kind(source) in [:single, :array] -> :choice
      true -> typed_kind(source, form)
    end
  end

  defp uuid_list_kind(source, form),
    do: if(many_to_many(source, form), do: :many_to_many, else: :text)

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
