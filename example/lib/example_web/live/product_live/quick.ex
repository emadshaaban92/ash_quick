defmodule ExampleWeb.ProductLive.Quick do
  @moduledoc """
  The page worth opening first.

  It shows most of what a QuickView does without being told: two relationship
  dropdowns on the form, a `Money` column, a textarea for `:text`, an array of
  atoms as a multi-select, an array of embedded attachments with an upload
  behind each, a saved filter, and `:reprice` offered as a row action because
  the resource defines it and the actor's policy allows it.
  """
  require Ash.Expr

  use AshQuick.LiveView.QuickView,
    resource: Example.Catalog.Product,
    load: [brand: [:name], category: [:name]],
    filters: [
      %{
        "name" => "on_sale",
        "label" => "On sale",
        "expression" => Ash.Expr.expr(:sale in tags or :clearance in tags)
      }
    ],
    list: [
      fields: [
        :sku,
        :name,
        {[brand: :name], label: "Brand"},
        {[category: :name], label: "Category"},
        :price,
        :tags,
        {:images, widget: &ExampleWeb.ImageWidgets.image/1},
        :active
      ],
      new_action_label: "Add Product"
    ],
    details: [
      fields: [
        :sku,
        :name,
        :description,
        {[brand: :name], label: "Brand"},
        {[category: :name], label: "Category"},
        :price,
        :tags,
        {:images, widget: &ExampleWeb.ImageWidgets.image/1},
        :active,
        :created_at,
        :updated_at
      ]
    ]
end
