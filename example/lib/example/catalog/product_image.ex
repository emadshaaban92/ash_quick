defmodule Example.Catalog.ProductImage do
  @moduledoc """
  One image on a product: the object plus what this product calls it.

  The attachment is wrapped in an embed rather than typed on the product
  directly because there is per-image metadata to keep. That is the convention
  `AshQuick.AshTypes.Attachment` documents — a field with nothing beyond
  storage is typed `:attachment`, one with more is an embed around it — and
  `AshQuick.LiveView.FormUtils` wires the upload through the embed's nested
  form either way.
  """
  use Ash.Resource, data_layer: :embedded

  attributes do
    attribute :attachment, :attachment,
      allow_nil?: true,
      public?: true,
      constraints: [visibility: :public, accepts: [:image], max_size_mb: 10]

    attribute :alt, :string, allow_nil?: true, public?: true
    attribute :featured, :boolean, allow_nil?: false, public?: true, default: false
  end
end
