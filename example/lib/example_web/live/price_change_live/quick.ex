defmodule ExampleWeb.PriceChangeLive.Quick do
  @moduledoc """
  An append-only log, routed `except: [:create]` — nothing creates a row by
  hand, so there is no "New" flow to offer.

  Its details page is also the half-bookkeeping case: the resource declares
  `created_at` / `created_by` and neither of the other two, so the header reads
  "Created by X on Y" with no second half.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Catalog.PriceChange,
    load: [product: [:name]],
    list: [
      fields: [
        {[product: :name], label: "Product"},
        :from_price,
        :to_price,
        :created_at
      ]
    ],
    details: [
      fields: [
        {[product: :name], label: "Product"},
        :from_price,
        :to_price,
        :created_at
      ]
    ]
end
