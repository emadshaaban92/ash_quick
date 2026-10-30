defmodule AshQuick.Labels do
  @moduledoc """
  The labels AshQuick draws, in the reader's language.

  A label is English wherever it comes from: a field, action or value name
  humanized (after `:humanize_overrides`), a `label:` option, a nav entry or
  group. Many are fixed when a QuickView or a nav compiles, so each is
  translated when it is drawn, on the process that renders, where the reader's
  locale is set. The English label is the msgid, looked up like AshQuick's own
  strings: in the `ash_quick` domain of the host's `:gettext` backend (see
  `AshQuick.Gettext`). With no backend, or no translation, a label is drawn as
  it is. `mix ash_quick.gen.gettext` lists the labels a host's pages draw.

  A custom template that draws a resource's fields, actions or values calls
  these, so it reads the same as the pages around it.
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
