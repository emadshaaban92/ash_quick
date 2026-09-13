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

      bucket = AshQuick.Config.s3_bucket()
      host = AshQuick.Config.s3_host()
      assert html =~ "https://#{bucket}.#{host}/public/products/abc.jpg"
      refute html =~ "X-Amz-Signature"
    end
  end
end
