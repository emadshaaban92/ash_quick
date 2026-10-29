defmodule AshQuick.Labels do
  @moduledoc """
  The labels AshQuick draws, in the reader's language.

  A label is English wherever it comes from: a field, action or value name
  humanized (after `:humanize_overrides`), a `label:` option, a nav entry or
  group. Many are fixed when a QuickView or a nav compiles, so each is handed
  to the host's `:label_translator` when it is drawn, on the process that
  renders, where the reader's locale is set. With no translator, a label is
  drawn as it is.

  A custom template that draws a resource's fields, actions or values calls
  these, so it reads the same as the pages around it.
  """

  alias AshQuick.LiveView.QuickField
  alias AshQuick.LiveView.Utils

  @doc """
  `label` through the `:label_translator`.

  Anything but a string is drawn as it is: `nil`, or markup a `label:` option
  holds.
  """
  def translate(label) when is_binary(label) do
    case AshQuick.Config.label_translator() do
      nil -> label
      {mod, fun} -> apply(mod, fun, [label])
    end
  end

  def translate(label), do: label

  @doc """
  The label of a field, action or value `name`: humanized, then translated.
  """
  def name(name), do: name |> Utils.humanize() |> translate()

  @doc """
  The label a `:fields` entry is drawn with, as a column, a details row, a
  filter or an export header: its `label:`, or its humanized name, translated.
  """
  def field(%QuickField{label: label}), do: translate(label)
  def field(field) when is_atom(field), do: name(field)
  def field({_, label}) when is_binary(label), do: translate(label)
  def field({field, _}) when is_atom(field), do: name(field)
  def field([field]), do: field(field)
end
