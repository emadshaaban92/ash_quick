defmodule AshQuick.Nav.Group do
  @moduledoc """
  A named set of paths, rendered as a sidebar heading and as one grid tile.

  A group holds path *references*, not entries: the same path may appear in
  more than one group, which is how a path that reads two ways (a price is
  catalog and it is finance) is filed under both without being declared twice.
  The paths it names need not be declared as entries at all — a path the
  router serves a QuickView at is an entry whether or not anything says so.

  Order is meaningful. The grid links a tile to the first path in the list
  that the viewer can actually reach, so the most representative path of a
  group belongs first.
  """

  defstruct [:label, :paths, :icon, __spark_metadata__: nil]
end
