defmodule Example.Uploads do
  @moduledoc """
  The host half of `AshQuick.Storage`.

  `Example.Uploads.ObjectStore` is what `config :ash_quick, storage:` points
  at. It signs through `AshQuick.Storage.S3` but names its own bucket, and it
  implements all three lifecycle callbacks: an arriving object is routed to
  `Example.Uploads.Quarantine` and withheld until something releases it.

  `Example.Uploads.FileObject` is where that custody is kept.
  """
  use Ash.Domain

  resources do
    resource Example.Uploads.FileObject
  end
end
