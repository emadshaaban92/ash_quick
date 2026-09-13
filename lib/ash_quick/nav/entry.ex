defmodule AshQuick.Nav.Entry do
  @moduledoc """
  One place a user can navigate to: a path, what to call it, and what to draw
  beside it.

  The unit of navigation is an entry, not a QuickView. A QuickView is only an
  entry that can fill itself in — `:label` comes from its resource and `:icon`
  from a default — so most of them need no declaration at all. Everything else
  a host routes (a scan page, a dashboard, a bulk importer) is an entry too,
  and says so explicitly.

  `:resource` is not declared. It is read off the route the path is served at,
  and is what a derived label is built from.
  """

  defstruct [:path, :label, :icon, :resource, __spark_metadata__: nil]
end
