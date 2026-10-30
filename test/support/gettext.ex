defmodule AshQuick.Test.Gettext do
  @moduledoc """
  The suite's stand-in for a host's Gettext backend, which `AshQuick.Gettext`
  forwards to. Its catalogue is the Arabic seed this package ships, so a test
  that puts `"ar"` on it reads AshQuick the way a host that copied the seed
  does.
  """
  use Gettext.Backend, otp_app: :ash_quick, priv: "priv/gettext_seeds"
end

defmodule AshQuick.Test.LabelGettext do
  @moduledoc """
  A host backend whose catalogue holds a few labels and nothing of AshQuick's
  own, for the tests that read a label translated: `ar` and `fr` under
  `test/support/gettext`.
  """
  use Gettext.Backend, otp_app: :ash_quick, priv: "test/support/gettext"
end

defmodule AshQuick.Test.TaskGettext do
  @moduledoc """
  The backend `mix ash_quick.gen.gettext` writes into in its own test: its
  `priv` is a scratch directory the test empties before and after.
  """
  use Gettext.Backend, otp_app: :ash_quick, priv: "tmp/gen_gettext_test"
end
