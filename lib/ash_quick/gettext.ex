defmodule AshQuick.Gettext do
  @moduledoc """
  Where AshQuick's own strings are marked for translation, and handed to the
  host's Gettext backend to be translated.

  Modules that render text `use Gettext, backend: AshQuick.Gettext` and call
  `gettext/1`; labels go through `AshQuick.Labels`. The domain defaults to
  `ash_quick`, so call sites never name it.

  This backend holds no translations. `priv/gettext/ash_quick.pot` is only the
  template `mix gettext.extract` writes from the call sites, so every lookup
  misses, and a miss is looked up in the backend `config :ash_quick, gettext:`
  names, in the same domain and in that backend's locale. A host translates
  AshQuick in its own `priv/gettext/<locale>/LC_MESSAGES/ash_quick.po`, written
  by `mix ash_quick.gen.gettext`. With no backend configured, everything is
  drawn in English.

  ## Translating

  From this repository:

      mix gettext.extract

  rewrites `priv/gettext/ash_quick.pot` from the `gettext/1` call sites. A
  locale this package offers a host to start from lives in
  `priv/gettext_seeds/<locale>/LC_MESSAGES/ash_quick.po`:

      mix gettext.merge priv/gettext_seeds/ar/LC_MESSAGES/ash_quick.po priv/gettext/ash_quick.pot

  folds new messages into it. `test/gettext_catalogue_test.exs` fails while a
  seed lacks a message, leaves one empty in any plural form, or still marks
  one fuzzy, which is what `gettext.merge` does when it guesses a new message
  from an old one.
  """
  use Gettext.Backend,
    otp_app: :ash_quick,
    priv: "priv/gettext",
    default_domain: "ash_quick"

  # The host's own lookup, in its own locale, so its answer comes back as it
  # gave it: `:default` when it has no translation either.
  @impl Gettext.Backend
  def handle_missing_translation(locale, domain, msgctxt, msgid, bindings) do
    case AshQuick.Config.gettext() do
      nil -> super(locale, domain, msgctxt, msgid, bindings)
      host -> host.lgettext(Gettext.get_locale(host), domain, msgctxt, msgid, bindings)
    end
  end

  @impl Gettext.Backend
  def handle_missing_plural_translation(locale, domain, msgctxt, msgid, plural, n, bindings) do
    case AshQuick.Config.gettext() do
      nil ->
        super(locale, domain, msgctxt, msgid, plural, n, bindings)

      host ->
        bindings = Map.put(bindings, :count, n)
        host.lngettext(Gettext.get_locale(host), domain, msgctxt, msgid, plural, n, bindings)
    end
  end
end
