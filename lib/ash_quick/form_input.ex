defmodule AshQuick.FormInput do
  @moduledoc """
  An input a form draws for every field of one Ash type, named in
  `config :ash_quick, form_inputs:`.

  A QuickView's `form: [widgets: ...]` names an input per field, on one page.
  This names one per type, for every form AshQuick draws: the create, update
  and bulk forms, and the sub-forms of embedded and related records, which a
  page's widgets never reach.

      config :ash_quick,
        form_inputs: %{
          MyApp.Types.Phone => MyAppWeb.PhoneInput,
          AshMoney.Types.Money => false
        }

  A key is an Ash type: a module, or a short name such as `:money` that Ash
  resolves to one. A field matches it when its type is that type, or an
  `Ash.Type.NewType` of it, however many deep: the field's own type is tried
  first, then each type under it, and the first one the map names wins. So a
  `MyApp.Types.Price` built on `AshMoney.Types.Money` gets the money input
  unless the map names `MyApp.Types.Price` itself. A list matches only a key
  that is a list, `{:array, MyApp.Types.Phone}`. A key naming no Ash type is
  refused with an `ArgumentError`, as a QuickView compiles or a form draws.

  A value is a module implementing this behaviour, or `false`, which turns off
  AshQuick's own input for the type so the field gets the plain text input.
  AshQuick's own, which the map replaces or turns off type by type:

    * `AshMoney.Types.Money` — `AshQuick.FormInput.Money`, an amount box and
      a currency select.

  ## Which input a field gets

  A page's `form: [widgets: ...]` entry for the field, then a `sensitive?`
  field's password input, which never shows the stored value, then this map,
  then AshQuick's other inputs (a record picker, a select over a fixed set of
  values, an upload, a date picker, the plain text input).

  ## The component

  `c:render/1` is a function component. It receives what AshQuick's own inputs
  do: `@field` (the Ash attribute or argument), `@phx_field` (the
  `Phoenix.HTML.FormField`), `@form` (the `AshPhoenix.Form`), `@resource`,
  `@scope`, `@uploads`, and `@help` (the field's help text,
  `AshQuick.Labels.help/2`, or nil). It draws the field's label, help and
  errors itself; `<.input help={@help} />` from `AshQuick.Components` draws
  all three. The form's grid has four columns; `sm:col-span-2` is half.
  The callback is `render/1` rather than `input/1` so that the module can
  import `AshQuick.Components.input/1` to draw with.

  It posts what the type casts, and Ash receives it as posted: an input
  posting a nested map (`form[phone][number]`) posts it to Ash as a map. The
  one exception is a field holding a `Money`, or any NewType of it: whatever
  input draws it, a posted `amount` has its digits read as a number's are
  (Arabic-Indic and Persian digits as 0-9, a decimal comma as a point).

  The map is read each time a form draws. A QuickView also reads it when it
  compiles, to know which lists its forms can save, so set it in
  `config.exs`. Changing it does not recompile the QuickViews: after adding
  or removing a list's entry, run `mix compile --force` for the check to see
  it.
  """

  @doc "Draws the field's input, label, help and errors."
  @callback render(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  # Named rather than referenced: AshQuick does not depend on `ash_money`.
  @built_in %{AshMoney.Types.Money => AshQuick.FormInput.Money}

  @doc false
  # The module that draws `field`, or nil when none does: the configured or
  # built-in input of the first type in its NewType chain either names.
  def module(field) do
    case named(field) do
      nil -> nil
      {type, module} -> loaded!(type, module)
    end
  end

  @doc false
  # Whether an input is named for `field`, without loading it: a QuickView
  # asks as it compiles, when the host's input may not be compiled yet.
  def named?(field), do: named(field) != nil

  defp named(%Ash.Resource.Attribute{type: type}), do: named_for(type)
  defp named(%Ash.Resource.Actions.Argument{type: type}), do: named_for(type)
  defp named(_field), do: nil

  defp named_for(type) do
    inputs = Map.merge(@built_in, configured())

    # `false` names a type too: it stops the walk, so a NewType turned off
    # does not get the input of the type under it.
    case Enum.find(chain(type), &Map.has_key?(inputs, &1)) do
      nil -> nil
      type -> if inputs[type], do: {type, inputs[type]}
    end
  end

  # The field's type, then each type it is a NewType of, one step at a time:
  # `Ash.Type.NewType.subtype_of/1` skips straight to the last.
  defp chain({:array, type}), do: type |> chain() |> Enum.map(&{:array, &1})

  defp chain(type) when is_atom(type) do
    type = Ash.Type.get_type(type)

    if Ash.Type.NewType.new_type?(type),
      do: [type | chain(type.subtype_of())],
      else: [type]
  end

  defp chain(_type), do: []

  defp configured do
    case Application.get_env(:ash_quick, :form_inputs, %{}) do
      inputs when is_map(inputs) ->
        Map.new(inputs, fn {type, input} -> {key!(type), validate!(type, input)} end)

      other ->
        raise ArgumentError,
              "config :ash_quick, form_inputs: must be a map of Ash type => module or false, " <>
                "got: #{inspect(other)}"
    end
  end

  # A key naming no type would match no field, so a misspelt one would leave
  # the input it was meant to replace or turn off silently in place. A
  # built-in's key is taken without its type loaded, as it is named.
  defp key!(type) do
    key = key(type)

    if Map.has_key?(@built_in, key) or Ash.Type.ash_type?(key),
      do: key,
      else:
        raise(ArgumentError, """
        config :ash_quick, form_inputs: names #{inspect(type)}, which is no Ash type. \
        A key is an Ash type: a module, a short name Ash resolves, or a list of one.
        """)
  end

  defp key({:array, type}), do: {:array, key(type)}
  defp key(type) when is_atom(type), do: Ash.Type.get_type(type)
  defp key(type), do: type

  defp validate!(_type, false), do: false
  defp validate!(_type, module) when is_atom(module) and module not in [nil, true], do: module

  defp validate!(type, other) do
    raise ArgumentError,
          "config :ash_quick, form_inputs: maps #{inspect(type)} to #{inspect(other)}; " <>
            "a value is a module implementing AshQuick.FormInput, or false"
  end

  defp loaded!(type, module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :render, 1),
      do: module,
      else:
        raise(ArgumentError, """
        config :ash_quick, form_inputs: names #{inspect(module)} for #{inspect(type)}, \
        which defines no render/1. A form input is a module implementing \
        AshQuick.FormInput, whose render/1 is a function component.
        """)
  end
end
