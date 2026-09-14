defmodule Example do
  @moduledoc """
  The AshQuick example application.

  Three domains, kept small enough that a failing test names one thing:

    * `Example.Accounts` — the `:actor_resource` every page runs as, and the
      `:audit_resource` every write lands a row in.
    * `Example.Catalog` — the resources the QuickViews are built over.
    * `Example.Uploads` — the host half of `AshQuick.Storage`: custody of an
      arriving object, and the state that decides whether it may be served.
  """
end
