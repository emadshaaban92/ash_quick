defmodule AshQuick.Labels do
  @moduledoc """
  The labels AshQuick draws, in the reader's language.

  A label is English wherever it comes from: a field, action or value name
  humanized, a resource's own `labels` (see `AshQuick`), a `label:` option,
  an enum's own label, a nav entry or group. Many are fixed when a QuickView
  or a nav compiles, so each is translated when it is drawn, on the process
  that renders, where the reader's locale is set. The English label is the
  msgid, looked up like AshQuick's own strings: in the `ash_quick` domain of
  the host's `:gettext` backend (see `AshQuick.Gettext`). With no backend, or
  no translation, a label is drawn as it is. `mix ash_quick.gen.gettext`
  lists the labels a host's pages draw.

  A label of a resource is looked up under the resource's context first
  (`context/2`: `msgctxt "loan"` for a field, action or argument,
  `"loan.status"` for a value), and without one after, so a language whose
  words agree with the noun they describe translates a label differently
  where it needs to, and nowhere else.

  A custom template that draws a resource's fields, actions or values calls
  these with the resource, so it reads the same as the pages around it: a
  label the resource declares is drawn in place of the humanized name, and
  `value/3` labels a value the way the pages do.
  """

  alias AshQuick.Labels.Catalogue
  alias AshQuick.LiveView.EnumOptions
  alias AshQuick.LiveView.QuickField
  alias AshQuick.LiveView.Utils

  @doc """
  `label` in the reader's language.

  With a `context` (`context/2`), the translation the catalogue gives `label`
  under that `msgctxt` is drawn, and `label`'s context-free translation where
  it gives none: a language whose words agree with the noun they describe
  translates "Cancelled" one way for a loan and another for an approval, and
  every other label needs no context. A label translated neither way reaches
  the backend's `handle_missing_translation/5` with its context.

  Anything but a string is drawn as it is: `nil`, or markup a `label:` option
  holds.
  """
  def translate(label, context \\ nil)

  def translate(label, context) when is_binary(label) do
    case AshQuick.Config.gettext() do
      nil -> label
      backend -> lookup(backend, Gettext.get_locale(backend), context, label)
    end
  end

  def translate(label, _context), do: label

  @doc """
  The `msgctxt` a label of `resource` is translated under: its short name,
  `"loan"`, for a field, action or argument, and that and the field's name,
  `"loan.status"`, for a value of `field_name`. `nil` without a resource.

  The short name is the resource's own (`resource do short_name ... end`), so
  two resources sharing one share their contexts.
  """
  def context(resource, field_name \\ nil)

  def context(nil, _field_name), do: nil

  def context(%resource{}, field_name), do: context(resource, field_name)

  def context(resource, field_name) when is_atom(resource) do
    if Ash.Resource.Info.resource?(resource) do
      short_name = Ash.Resource.Info.short_name(resource)
      if field_name, do: "#{short_name}.#{field_name}", else: "#{short_name}"
    end
  end

  # Straight to the host's backend: AshQuick's own would only miss and forward.
  # A label is text, not a message with bindings, so a `%{` in it (or in its
  # translation) is drawn as written rather than raising.
  defp lookup(backend, locale, context, label) do
    msgctxt = if context, do: msgctxt(backend, locale, context, label)

    case backend.lgettext(locale, "ash_quick", msgctxt, label, %{}) do
      {:missing_bindings, drawn, _bindings} -> drawn
      {_found_or_default, drawn} -> drawn
    end
  end

  # The entry to ask for: the contexted one when it is translated, the
  # context-free one when only that is, and the contexted one when neither is,
  # so the missing-translation hook names the variant that was wanted.
  defp msgctxt(backend, locale, context, label) do
    case Catalogue.translated(backend, locale) do
      :unknown ->
        nil

      translated ->
        cond do
          MapSet.member?(translated, {context, label}) -> context
          MapSet.member?(translated, {nil, label}) -> nil
          true -> context
        end
    end
  end

  @doc """
  The label of a field, action or argument `name` of `resource`: the label the
  resource declares for it, or its name humanized, translated.

  Without a resource, the name humanized, translated.
  """
  def name(name, resource \\ nil),
    do: name |> english(resource) |> translate(context(resource))

  @doc """
  The label a `:fields` entry is drawn with, as a column, a details row, a
  filter or an export header: its `label:`, or the label `resource` declares
  for the field it names, or its name humanized, translated.

  A QuickView's own fields already carry their label, so `resource` is only
  read for an entry as written under `:fields`. A relationship path is
  labelled by the field it reaches on the related resource, `[owner: :name]`
  by the owner's `:name`.
  """
  def field(field, resource \\ nil)

  def field(%QuickField{label: label, context: context}, _resource),
    do: translate(label, context)

  def field([field], resource) when is_atom(field), do: field(field, resource)
  def field(field, resource), do: field |> QuickField.normalize(resource) |> field()

  @doc """
  The label `value` of the field, or action argument, `field_name` of
  `resource` is drawn with: the label the resource declares for that value
  (`label :status, :paid_off, "Paid Off in Full"`), else its enum's label when
  the field is typed by an `Ash.Type.Enum`, else its name humanized,
  translated. A field the resource lacks labels `value` humanized. `nil` is
  drawn as nothing.

      Labels.value(MyApp.Loan, :status, @record.status)
  """
  def value(resource, field_name, value)

  def value(_resource, _field_name, nil), do: nil

  def value(resource, field_name, value) do
    field = value_field(resource, field_name) || %{name: field_name, type: nil}
    EnumOptions.label(field, value, resource)
  end

  # A value belongs to a field, or to an argument of one of the actions.
  defp value_field(resource, name) do
    if Ash.Resource.Info.resource?(resource) do
      Ash.Resource.Info.field(resource, name) ||
        resource
        |> Ash.Resource.Info.actions()
        |> Enum.find_value(fn action -> Enum.find(action.arguments, &(&1.name == name)) end)
    end
  end

  @doc false
  # The English label of `name` on `resource`, before translating: the msgid.
  def english(name, resource \\ nil) do
    declared(resource, name) || Utils.humanize(name)
  end

  @doc false
  # The label `resource` declares under `key`: a name, or `{name, value}`.
  def declared(nil, _key), do: nil
  def declared(%resource{}, key), do: declared(resource, key)

  def declared(resource, key) when is_atom(resource) do
    if Ash.Resource.Info.resource?(resource) do
      resource |> Spark.Dsl.Extension.get_persisted(:ash_quick_labels, %{}) |> Map.get(key)
    end
  end
end
