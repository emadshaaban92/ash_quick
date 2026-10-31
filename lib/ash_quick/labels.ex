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

  A custom template that draws a resource's fields, actions or values calls
  these with the resource, so it reads the same as the pages around it: a
  label the resource declares is drawn in place of the humanized name. A
  value's label is `AshQuick.LiveView.EnumOptions.label/3`.
  """

  alias AshQuick.LiveView.QuickField
  alias AshQuick.LiveView.Utils

  @doc """
  `label` in the reader's language.

  Anything but a string is drawn as it is: `nil`, or markup a `label:` option
  holds.
  """
  def translate(label) when is_binary(label) do
    case AshQuick.Config.gettext() do
      nil -> label
      backend -> lookup(backend, label)
    end
  end

  def translate(label), do: label

  # Straight to the host's backend: AshQuick's own would only miss and forward.
  # A label is text, not a message with bindings, so a `%{` in it (or in its
  # translation) is drawn as written rather than raising.
  defp lookup(backend, label) do
    case backend.lgettext(Gettext.get_locale(backend), "ash_quick", nil, label, %{}) do
      {:missing_bindings, drawn, _bindings} -> drawn
      {_found_or_default, drawn} -> drawn
    end
  end

  @doc """
  The label of a field, action or argument `name` of `resource`: the label the
  resource declares for it, or its name humanized, translated.

  Without a resource, the name humanized, translated.
  """
  def name(name, resource \\ nil), do: name |> english(resource) |> translate()

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
  def field(%QuickField{label: label}, _resource), do: translate(label)
  def field([field], resource) when is_atom(field), do: field(field, resource)
  def field(field, resource), do: field |> QuickField.normalize(resource) |> field()

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
