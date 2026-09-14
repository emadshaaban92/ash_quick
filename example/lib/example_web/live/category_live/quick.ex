defmodule ExampleWeb.CategoryLive.Quick do
  @moduledoc """
  A tree, rendered flat with the parent named.

  `{[parent: :name], label: "Parent"}` is a relationship path: the view loads
  the relationship and reads a field off it, which is how a dropdown's
  currently-selected option shows a name rather than a UUID.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Catalog.Category,
    list: [
      fields: [
        :code,
        :name,
        {[parent: :name], label: "Parent"},
        {:image, widget: &ExampleWeb.ImageWidgets.image/1},
        :active
      ],
      new_action_label: "Add Category"
    ],
    details: [
      fields: [
        :code,
        :name,
        {[parent: :name], label: "Parent"},
        {:image, widget: &ExampleWeb.ImageWidgets.image/1},
        :active,
        :created_at,
        :updated_at
      ]
    ]
end
