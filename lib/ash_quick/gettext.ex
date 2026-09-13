defmodule AshQuick.Gettext do
  @moduledoc """
  The Gettext backend for AshQuick's own user-facing strings.

  AshQuick renders its own markup, so it translates its own strings rather than
  handing them back to the host the way `AshQuick.Config.error_translator` does
  for Ash error messages.

  Modules that render text `use Gettext, backend: AshQuick.Gettext` and call
  `gettext/1`. The domain defaults to `ash_quick`, so call sites never name it
  and the catalogue stays separate from the host's own `default` and `errors`
  domains.

  The catalogue ships inside this package's own `priv/gettext`, so a host adds
  no `.po` files of its own and `mix gettext.extract` in the host does not see
  these strings.

  ## Translating

  From this repository:

      mix gettext.extract
      mix gettext.merge priv/gettext --locale ar

  `gettext.extract` rewrites `priv/gettext/ash_quick.pot` from the `gettext/1`
  call sites; `gettext.merge` folds new messages into each locale's `.po`
  without disturbing the translations already there.
  """
  use Gettext.Backend,
    otp_app: :ash_quick,
    priv: "priv/gettext",
    default_domain: "ash_quick"
end
