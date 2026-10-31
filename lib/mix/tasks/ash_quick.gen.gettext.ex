defmodule Mix.Tasks.AshQuick.Gen.Gettext do
  @shortdoc "Writes the template a host translates AshQuick in"

  @moduledoc """
  Writes `ash_quick.pot` into the `priv` of the Gettext backend
  `config :ash_quick, gettext:` names: every string AshQuick draws, its own
  and the labels this application's pages draw.

      mix ash_quick.gen.gettext
      mix ash_quick.gen.gettext --locale ar
      mix ash_quick.gen.gettext --check

  Labels (field, action and value names, or the labels their resource declares
  for them, `label:` options, nav entries, page titles) are not `gettext` call
  sites, so `mix gettext.extract` cannot find them. This reads them off the nav and the QuickViews its router serves,
  together with the resources they reach. A label it cannot read, such as the
  title of a bulk item a function builds, is marked where the host writes it,
  with `dgettext_noop("ash_quick", "…")`: `mix gettext.extract` adds it to the
  same template, and this task keeps it. Run either in any order (this task
  orders messages by the project's `gettext: [sort_by_msgid: ...]` as
  `gettext.extract` does), then fold the template into each locale as usual:

      mix gettext.merge priv/gettext

  ## Options

    * `--locale` / `-l` — also copy the translation this package ships for
      that locale (Arabic, `ar`), when the backend has no
      `<locale>/LC_MESSAGES/ash_quick.po` yet. `gettext.merge` then adds the
      labels to it. A locale with no seed is created by
      `mix gettext.merge priv/gettext --locale <locale>`.

    * `--check` — write nothing, and fail when the template on disk differs
      from the one this would write: a field, an action or a nav entry was
      added and nobody regenerated it. For CI, next to
      `mix gettext.extract --check-up-to-date`.

  Labels come from the router the nav declares as it is compiled in the
  current environment, so run both in the same one, the one the pages ship
  in: a router that serves test-only pages in `test` lists their labels too.
  """

  use Mix.Task

  alias AshQuick.Gettext.Template

  # The nav, the router and the resources are read by introspection, as
  # `mix ash_quick.check` reads them: compiled and configured, not started.
  @requirements ["app.config"]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} =
      OptionParser.parse!(argv, strict: [locale: :string, check: :boolean], aliases: [l: :locale])

    priv = priv()
    path = Path.join(priv, "ash_quick.pot")
    existing = if File.exists?(path), do: Expo.PO.parse_file!(path)

    template =
      AshQuick.Config.nav()
      |> Template.build(existing, sort_by_msgid: sort_by_msgid())
      |> Expo.PO.compose()
      |> IO.iodata_to_binary()

    if opts[:check] do
      check(path, template)
    else
      File.mkdir_p!(priv)
      File.write!(path, template)
      Mix.shell().info([:green, "* writing ", :reset, path])

      if locale = opts[:locale], do: seed(priv, locale)

      Mix.shell().info("\nNow run: mix gettext.merge #{priv}")
    end
  end

  defp priv do
    case AshQuick.Config.gettext() do
      nil ->
        Mix.raise("""
        mix ash_quick.gen.gettext writes into the priv of the Gettext backend AshQuick
        translates through, and none is configured:

            config :ash_quick, gettext: MyAppWeb.Gettext
        """)

      backend ->
        backend.__gettext__(:priv)
    end
  end

  # Read as `mix gettext.extract` reads it, so the two write the same order.
  defp sort_by_msgid do
    case Mix.Project.config()[:gettext][:sort_by_msgid] do
      true -> :case_sensitive
      sort -> sort
    end
  end

  defp check(path, template) do
    if File.read(path) != {:ok, template} do
      Mix.raise("#{path} is out of date; run `mix ash_quick.gen.gettext`")
    end
  end

  defp seed(priv, locale) do
    target = Path.join([priv, locale, "LC_MESSAGES", "ash_quick.po"])

    case {Template.seed(locale), File.exists?(target)} do
      {_seed, true} ->
        Mix.shell().info("#{target} already exists; leaving it as it is")

      {nil, false} ->
        Mix.shell().info(
          "AshQuick ships no #{locale} translation; " <>
            "`mix gettext.merge #{priv} --locale #{locale}` creates an empty one"
        )

      {seed, false} ->
        File.mkdir_p!(Path.dirname(target))
        File.cp!(seed, target)
        Mix.shell().info([:green, "* copying ", :reset, target])
    end
  end
end
