defmodule ExampleWeb.BrandLive.Quick do
  @moduledoc """
  The smallest QuickView there is: a resource, and the fields to show.

  Everything else — filtering, sorting, pagination, the create and update
  forms, the export menu, the row actions, the live updates — is derived from
  the resource.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Catalog.Brand,
    list: [
      fields: [:code, :name, :active],
      new_action_label: "Add Brand"
    ],
    details: [
      fields: [:code, :name, :active, :created_at, :updated_at]
    ]
end
