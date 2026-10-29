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

  @english {__MODULE__, :english}

  @doc """
  `label` through the `:label_translator`.

  Anything but a string is drawn as it is: `nil`, or markup a `label:` option
  holds.
  """
  def translate(label) when is_binary(label) do
    case translator() do
      nil -> label
      {mod, fun} -> apply(mod, fun, [label])
    end
  end

  def translate(label), do: label

  @doc """
  Runs `fun` with every label in this process left in English, whatever the
  `:label_translator` says: how `AshQuick.Labels.Catalogue` reads the msgids
  through the same functions the pages draw with. Other processes are
  untouched.
  """
  def english(fun) do
    previous = Process.put(@english, true)

    try do
      fun.()
    after
      if previous, do: Process.put(@english, previous), else: Process.delete(@english)
    end
  end

  defp translator do
    if Process.get(@english), do: nil, else: AshQuick.Config.label_translator()
  end

  @doc """
  The label of a field, action or value `name`: humanized, then translated.
  """
  def name(name), do: name |> Utils.humanize() |> translate()

  @doc """
  What one record of `resource` is called: the details page's title and the
  form's.
  """
  def resource(resource), do: resource |> Ash.Resource.Info.short_name() |> name()

  @doc """
  What `resource`'s records are called together: the list's title. Its
  `plural_name`, or its short name with an "s".
  """
  def plural(resource) do
    case Ash.Resource.Info.plural_name(resource) do
      nil -> name("#{Ash.Resource.Info.short_name(resource)}s")
      plural -> name(plural)
    end
  end

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
