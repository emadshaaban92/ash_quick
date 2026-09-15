defmodule ExampleWeb.PriceChangeLive.Quick do
  @moduledoc """
  An append-only log, routed `except: [:create]` — nothing creates a row by
  hand, so there is no "New" flow to offer.

  Its details page is also the half-bookkeeping case: the resource declares
  `created_at` / `created_by` and neither of the other two, so the header reads
  "Created by X on Y" with no second half.

  `:product` is written bare rather than as `{[product: :name], label: ...}`.
  A relationship with no field named after it renders the destination's display
  label, which for a product *is* its name — so the path would only restate
  what the resource already declares. Spell a path out when you want some other
  field of the related record.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Catalog.PriceChange,
    load: [product: [:name]],
    list: [
      fields: [
        :product,
        :from_price,
        :to_price,
        :created_at
      ]
    ],
    details: [
      fields: [
        :product,
        :from_price,
        :to_price,
        :created_at
      ]
    ]
end
