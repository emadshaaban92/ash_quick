defmodule AshQuick.LiveView.Components.FieldValueTest do
  @moduledoc """
  What an attachment renders as, per file type and per visibility.

  The URL itself is `AshQuick.Storage`'s; what is pinned here is that the
  component asks for one and puts it in the right element — a `<video>` behind
  an `<img>` plays nothing, and a public key rendered through the signing path
  produces a URL that expires.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AshQuick.AshTypes.Attachment.Value
  alias AshQuick.LiveView.Components.FieldValue

  describe "field_value/1" do
    # The fixture host answers `object_states/1` from rows it keeps, so holding
    # an object is a row saying so.
    defp hold(key, state) do
      AshQuick.Test.Uploads.StoredObject
      |> Ash.Changeset.for_create(:create, %{serving_key: key, state: state})
      |> Ash.create!()
    end

    test "a single attachment field shows the state the host holds it in" do
      hold("private/return_requests/held.jpg", :processing)
      hold("private/return_requests/refused.jpg", :rejected)

      for {key, label} <- [
            {"private/return_requests/held.jpg", "Processing"},
            {"private/return_requests/refused.jpg", "Rejected"}
          ] do
        html =
          render_component(&FieldValue.field_value/1,
            ash_field: %{type: AshQuick.AshTypes.Attachment},
            value: %Value{key: key, file_type: :image}
          )

        assert html =~ label
        refute html =~ "<img"
      end
    end

    test "a multiple attachment field shows the state the host holds each in" do
      hold("private/return_requests/held.jpg", :processing)

      html =
        render_component(&FieldValue.field_value/1,
          ash_field: %{type: {:array, AshQuick.AshTypes.Attachment}},
          value: [%Value{key: "private/return_requests/held.jpg", file_type: :image}]
        )

      assert html =~ "Processing"
      refute html =~ "<img"
    end
  end

  describe "attachment_preview/1" do
    test "renders an <img> for image attachments" do
      value = %Value{key: "public/products/abc.jpg", file_type: :image}
      html = render_component(&FieldValue.attachment_preview/1, value: value)

      assert html =~ "<img"
      assert html =~ "public/products/abc.jpg"
      refute html =~ "<video"
    end

    test "renders a <video> element for video attachments" do
      value = %Value{key: "private/return_requests/abc.mp4", file_type: :video}
      html = render_component(&FieldValue.attachment_preview/1, value: value)

      assert html =~ "<video"
      assert html =~ "controls"
      assert html =~ "<source"
      refute html =~ "<img"
    end

    test "renders a link, not an <img>, for document attachments" do
      value = %Value{
        key: "private/return_requests/receipt.pdf",
        file_type: :document,
        original_filename: "purchase receipt.pdf"
      }

      html = render_component(&FieldValue.attachment_preview/1, value: value)

      assert html =~ ~s(href="https://)
      assert html =~ "private/return_requests/receipt.pdf"
      assert html =~ "purchase receipt.pdf"
      assert html =~ ~s(rel="noopener noreferrer")
      refute html =~ "<img"
    end

    test "renders the placeholder, not a link, for a document the host is holding" do
      value = %Value{key: "private/return_requests/receipt.pdf", file_type: :document}

      html =
        render_component(&FieldValue.attachment_preview/1,
          value: value,
          states: %{"private/return_requests/receipt.pdf" => :processing}
        )

      assert html =~ "Processing"
      refute html =~ "href="
    end

    test "renders empty span for nil value" do
      html = render_component(&FieldValue.attachment_preview/1, value: nil)
      assert html =~ "<span></span>"
    end

    test "private attachments use signed URLs (with a Signature parameter)" do
      value = %Value{key: "private/return_requests/abc.mp4", file_type: :video}
      html = render_component(&FieldValue.attachment_preview/1, value: value)

      assert html =~ "X-Amz-Signature" or html =~ "Signature="
    end

    test "public attachments use deterministic HTTPS URLs (no signature)" do
      value = %Value{key: "public/products/abc.jpg", file_type: :image}
      html = render_component(&FieldValue.attachment_preview/1, value: value)

      # The configured seam's bucket, not `AshQuick.Config.s3_bucket/0`: what is
      # pinned is that the component resolves through `AshQuick.Storage` rather
      # than building a URL of its own.
      bucket = AshQuick.Test.Uploads.ObjectStore.bucket()
      host = AshQuick.Test.Uploads.ObjectStore.host()
      assert html =~ "https://#{bucket}.#{host}/public/products/abc.jpg"
      refute html =~ "X-Amz-Signature"
    end
  end
end
