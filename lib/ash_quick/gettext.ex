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
  AshQuick in its own `priv/gettext/<locale>/LC_MESSAGES/ash_quick.po`, merged
  from the template `mix ash_quick.gen.gettext` writes. With no backend
  configured, everything is drawn in English.

  A message the host's backend has no translation for either is emitted as
  `[:ash_quick, :translation, :missing]` (see `AshQuick.Telemetry`), after
  the backend's own `handle_missing_translation/5` has answered, so a host
  can log or test for the gaps in its `ash_quick.po` without overriding it.

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
  # gave it: `:default` when it has no translation either, which is also
  # emitted as `[:ash_quick, :translation, :missing]`.
  @impl Gettext.Backend
  def handle_missing_translation(locale, domain, msgctxt, msgid, bindings) do
    case AshQuick.Config.gettext() do
      nil ->
        super(locale, domain, msgctxt, msgid, bindings)

      host ->
        host_locale = Gettext.get_locale(host)

        host_locale
        |> host.lgettext(domain, msgctxt, msgid, bindings)
        |> missed(host, host_locale, domain, msgctxt, msgid, nil)
    end
  end

  @impl Gettext.Backend
  def handle_missing_plural_translation(locale, domain, msgctxt, msgid, plural, n, bindings) do
    case AshQuick.Config.gettext() do
      nil ->
        super(locale, domain, msgctxt, msgid, plural, n, bindings)

      host ->
        host_locale = Gettext.get_locale(host)
        bindings = Map.put(bindings, :count, n)

        host_locale
        |> host.lngettext(domain, msgctxt, msgid, plural, n, bindings)
        |> missed(host, host_locale, domain, msgctxt, msgid, plural)
    end
  end

  @doc false
  # Emits `[:ash_quick, :translation, :missing]` when the host's answer is
  # `:default`, a lookup it had no translation for, and hands the answer back
  # as it came. `AshQuick.Labels` reports its own lookups through it.
  def missed(answer, backend, locale, domain, msgctxt, msgid, msgid_plural) do
    if elem(answer, 0) == :default do
      AshQuick.Telemetry.event([:translation, :missing], %{
        backend: backend,
        locale: locale,
        domain: domain,
        msgctxt: msgctxt,
        msgid: msgid,
        msgid_plural: msgid_plural
      })
    end

    answer
  end
end
