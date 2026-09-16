defmodule ExampleWeb.StoreLive.Quick do
  @moduledoc """
  The tenants themselves.

  A page over the thing everything else is partitioned *by*, which is why the
  resource behind it is not multitenant: a list of stores readable only from
  inside one would have nothing on it.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Catalog.Store,
    list: [
      fields: [:code, :name, :active],
      new_action_label: "Open a Store"
    ],
    details: [
      fields: [:code, :name, :active, :created_at, :updated_at]
    ]
end
