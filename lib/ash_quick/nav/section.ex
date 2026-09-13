defmodule AshQuick.Nav.Section do
  @moduledoc """
  A group and the entries under it that the viewer can reach, as the sidebar
  and the grid consume it.

  `:group` is `nil` for the one section holding entries that belong to no
  group — the sidebar renders it without a heading, and the grid skips it,
  since a tile is a group.
  """

  defstruct [:group, :entries]
end
