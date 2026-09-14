defmodule ExampleWeb.FileObjectLive.Quick do
  @moduledoc """
  What the storage seam is holding: one row per object, and how far along it is.

  Routed `only: [:index, :show]` — a row appears when a file is picked, not
  when someone fills in a form.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Uploads.FileObject,
    load: [actor: [:name]],
    list: [
      fields: [
        :key,
        :state,
        :source,
        :original_filename,
        :resource_name,
        :referenced_at,
        {[actor: :name], label: "Uploaded by"},
        :created_at
      ]
    ],
    details: [
      fields: [
        :key,
        :state,
        :source,
        :original_filename,
        :content_type,
        :byte_size,
        :accepts,
        :max_bytes,
        :resource_name,
        :resource_id,
        :referenced_at,
        {[actor: :name], label: "Uploaded by"},
        :created_at,
        :updated_at
      ]
    ]
end
