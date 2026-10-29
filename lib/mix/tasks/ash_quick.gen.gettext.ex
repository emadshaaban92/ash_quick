defmodule Mix.Tasks.AshQuick.Gen.Gettext do
  @shortdoc "Writes the labels AshQuick draws into a Gettext template"

  @moduledoc """
  Writes every label AshQuick draws for this application into a Gettext
  template, for the `:label_translator` to look up.

      mix ash_quick.gen.gettext
      mix gettext.merge priv/gettext --no-fuzzy

  The labels are what `AshQuick.Labels.Catalogue` reads, in English, each one
  the msgid the translator is handed. A label is not a `gettext` call, so
  `mix gettext.extract` does not find them; run this after adding a field,
  an action, an enum value or a nav entry, then merge. Pass `--no-fuzzy` to
  the merge: Gettext uses a fuzzy entry at runtime, and a label guessed from
  another one is a wrong label on the page.

  Nothing is written as `elixir-autogen`, so `mix gettext.extract` leaves the
  file alone.

  ## Options

    * `--domain` — the template's domain, `labels` by default: the one the
      translator reads, `Gettext.dgettext(MyAppWeb.Gettext, "labels", label)`.
    * `--priv` — where the templates are, `priv/gettext` by default.
    * `--check-up-to-date` — writes nothing, and fails when the template is
      not what it would write. For CI.
  """

  use Mix.Task

  alias AshQuick.Labels.Catalogue

  # The router and the QuickViews are read by introspection: compiled and
  # configured, not started.
  @requirements ["app.config"]

  @header """
  This file is a PO Template file, written by `mix ash_quick.gen.gettext`
  from the labels AshQuick draws. Do not edit it: run the task again, then
  `mix gettext.merge priv/gettext --no-fuzzy`, and translate in the `.po`
  files.\
  """

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv,
        strict: [domain: :string, priv: :string, check_up_to_date: :boolean]
      )

    path = Path.join(opts[:priv] || "priv/gettext", "#{opts[:domain] || "labels"}.pot")
    content = template(Catalogue.labels())

    if opts[:check_up_to_date], do: check(path, content), else: write(path, content)
  end

  defp write(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    Mix.shell().info("Wrote #{path}")
  end

  defp check(path, content) do
    if File.read(path) != {:ok, content},
      do: Mix.raise("#{path} is not up to date. Run mix ash_quick.gen.gettext")
  end

  @doc false
  def template(labels) do
    messages =
      for {label, sources} <- labels do
        %Expo.Message.Singular{msgid: [label], msgstr: [""], references: Enum.map(sources, &[&1])}
      end

    %Expo.Messages{
      top_comments: @header |> String.split("\n") |> Enum.map(&[" " <> &1]),
      headers: [""],
      messages: messages
    }
    |> Expo.PO.compose()
    |> IO.iodata_to_binary()
  end
end
