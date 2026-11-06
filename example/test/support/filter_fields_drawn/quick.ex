defmodule Example.Test.FilterFieldsDrawnNoneLive.Quick do
  @moduledoc """
  The page over `Example.Test.FilterFields` whose list offers no filter, drawn
  by a list template of its own, `action_index.html.heex`, which names the
  list's attributes and leaves `filterable` unsaid. Routed only in the test
  build.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.FilterFields,
    list: [fields: [:code, :active], filterable: []],
    details: [fields: [:code]]
end

defmodule Example.Test.FilterFieldsDrawnNamedLive.Quick do
  @moduledoc """
  The page over `Example.Test.FilterFields` whose filter offers a stage and a
  code, drawn by the same list template as
  `Example.Test.FilterFieldsDrawnNoneLive.Quick`. Routed only in the test
  build.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.FilterFields,
    list: [fields: [:code, :active], filterable: [:stage, :code]],
    details: [fields: [:code]]
end
