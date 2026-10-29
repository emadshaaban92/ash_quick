defmodule AshQuick.Test.LabelCatalogue.Gettext do
  @moduledoc """
  The `:label_gettext_backend` of the suite: the backend the QuickViews and
  navs here get their `gettext` calls for. It has no catalogue of its own.

  In a file of its own: while messages are extracted, every QuickView's calls
  read this backend as they compile, and one defined beside a QuickView would
  wait on that QuickView in turn.
  """
  use Gettext.Backend, otp_app: :ash_quick, priv: "test/support/gettext"
end
