defmodule ExampleWeb.Gettext do
  @moduledoc """
  A module providing Internationalization with a gettext-based API.

  By using [Gettext](https://hexdocs.pm/gettext), your module compiles translations
  that you can use in your application. To use this Gettext backend module,
  call `use Gettext` and pass it as an option:

      use Gettext, backend: ExampleWeb.Gettext

      # Simple translation
      gettext("Here is the string to translate")

      # Plural translation
      ngettext("Here is the string to translate",
               "Here are the strings to translate",
               3)

      # Domain-based translation
      dgettext("errors", "Here is the error message to translate")

  See the [Gettext Docs](https://hexdocs.pm/gettext) for detailed usage.
  """
  use Gettext.Backend, otp_app: :example

  require Logger

  # On in dev only (`config/dev.exs`): the point while looking at a page,
  # noise in production logs.
  @warn_missing? Application.compile_env(:example, :warn_missing_translations, false)

  # The language the msgids are written in, which has nothing to miss. Not
  # the default locale: an app defaulting to another language still needs to
  # hear what that one lacks.
  @source_locale "en"

  @doc """
  Logs a message the reader's locale has no translation for, then draws the
  msgid as Gettext would. Each one is logged once per process, so a list
  page names an untranslated enum value once rather than once per row.

  Every label AshQuick draws goes through `translate_label/1`, so a field,
  action, enum value or nav entry `labels.po` lacks is named here as soon as
  a page draws it.
  """
  @impl Gettext.Backend
  def handle_missing_translation(locale, domain, msgctxt, msgid, bindings) do
    key = {__MODULE__, :missing, locale, domain, msgctxt, msgid}

    if @warn_missing? and locale != @source_locale and !Process.get(key) do
      Process.put(key, true)
      Logger.warning("Missing #{locale} translation in #{domain}: #{inspect(msgid)}")
    end

    super(locale, domain, msgctxt, msgid, bindings)
  end

  @doc """
  A label AshQuick draws, in the reader's language: the `:label_translator`.

  The English label is the msgid, so a field, action or nav entry is
  translated in `priv/gettext/<locale>/LC_MESSAGES/labels.po`, and one the
  catalogue lacks is drawn in English, and logged in dev.
  """
  def translate_label(label), do: Gettext.dgettext(__MODULE__, "labels", label)
end
