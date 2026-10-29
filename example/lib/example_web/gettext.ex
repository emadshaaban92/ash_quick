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

  @doc """
  A label AshQuick draws, in the reader's language: the `:label_translator`.

  The English label is the msgid, so a field, action or nav entry is
  translated in `priv/gettext/<locale>/LC_MESSAGES/labels.po`, and one the
  catalogue lacks is drawn in English. This is also the
  `:label_gettext_backend`, so `mix gettext.extract` finds them.
  """
  def translate_label(label), do: Gettext.dgettext(__MODULE__, "labels", label)
end
