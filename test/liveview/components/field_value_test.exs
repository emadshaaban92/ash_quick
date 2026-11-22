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
    # The fixture host answers `object_states/2` from rows it keeps, so holding
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

    test "reads states on behalf of the page's scope" do
      scope = %{actor: %{id: "viewer"}}

      render_component(&FieldValue.field_value/1,
        path: [],
        ash_field: %{type: AshQuick.AshTypes.Attachment},
        value: %Value{key: "private/return_requests/any.jpg", file_type: :image},
        scope: scope
      )

      assert AshQuick.Test.Uploads.ObjectStore.last_object_states_opts() == [scope: scope]
    end
  end

  describe "field_value/1 on dates and times" do
    # Each reads as `AshQuick.Config` formats it, the way a `DateTime` always
    # has, and not as the ISO 8601 `Phoenix.HTML.Safe` would print.
    for {label, value, formatted, iso} <- [
          {"a date", quote(do: ~D[2026-10-19]), "Oct 19, 2026", "2026-10-19"},
          {"a time", quote(do: ~T[19:54:10]), "7:54:10", "19:54:10"},
          {"a naive datetime", quote(do: ~N[2026-10-19 19:54:10]), "Oct 19, 2026, 7:54:10",
           "2026-10-19T19:54:10"},
          {"a datetime", quote(do: ~U[2026-10-19 19:54:10.123456Z]), "Oct 19, 2026, 7:54:10",
           "2026-10-19T19:54:10"}
        ] do
      test "#{label} reads as the configured format" do
        html =
          render_component(&FieldValue.field_value/1,
            path: [],
            value: unquote(value)
          )

        assert html =~ unquote(formatted)
        refute html =~ unquote(iso)
      end
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

  describe "field_value/1 on numbers" do
    # Read left to right on a right-to-left page too, so a minus sign stays
    # in front of the digits instead of landing after them.
    for {label, type, value, shown} <- [
          {"an integer", Ash.Type.Integer, quote(do: -12_345), "-12,345"},
          {"a float", Ash.Type.Float, quote(do: -2.5), "-2.5"},
          {"a decimal", Ash.Type.Decimal, quote(do: Decimal.new("-10.50")), "-10.50"}
        ] do
      test "isolates #{label} left to right" do
        html =
          render_component(&FieldValue.field_value/1,
            value: unquote(value),
            path: [],
            ash_field: %{type: unquote(type)}
          )

        assert html =~ ~s(<span dir="ltr">#{unquote(shown)}</span>)
      end
    end
  end

  describe "field_value/1 on text" do
    # Text people typed reads in its own direction. One with no letter is a
    # number, a code or a phone number, and reads left to right on a
    # right-to-left page too, whatever a browser falls back on for
    # `dir="auto"` when it finds no letter.
    for {label, value, dir} <- [
          {"a phone number", "+20 100 123 4567", "ltr"},
          {"a string of digits", "-12345", "ltr"},
          {"a code of digits and signs", "(02) 2345-6789 #12", "ltr"},
          {"a Latin name", "Acme Inc.", "auto"},
          {"an Arabic name", "شركة النيل", "auto"},
          {"an Arabic name with a number in it", "فرع 12", "auto"},
          {"an empty string", "", "ltr"}
        ] do
      test "gives #{label} dir=#{dir}" do
        html =
          render_component(&FieldValue.field_value/1,
            value: unquote(value),
            path: [],
            ash_field: %{type: Ash.Type.String}
          )

        assert html =~ ~s(<span dir="#{unquote(dir)}">)
      end
    end

    test "reads a case-insensitive string as the text it holds" do
      for {value, dir} <- [{"+20 100 123 4567", "ltr"}, {"Acme Inc.", "auto"}] do
        html =
          render_component(&FieldValue.field_value/1,
            value: Ash.CiString.new(value),
            path: [],
            ash_field: %{type: Ash.Type.CiString}
          )

        assert html =~ ~s(<span dir="#{dir}">#{value}</span>)
      end
    end

    test "text_dir/1 reads a number left to right, and draws no dir for what is no text" do
      assert FieldValue.text_dir(42) == "ltr"
      assert FieldValue.text_dir(~D[2026-11-22]) == "ltr"
      assert FieldValue.text_dir(nil) == nil
      assert FieldValue.text_dir(%{name: "x"}) == nil
      assert FieldValue.text_dir(%Ash.NotLoaded{}) == nil
    end

    # Bytes that are not UTF-8 cannot be searched for a letter, and are left
    # to the browser rather than taking the page down.
    test "text_dir/1 leaves bytes that are not UTF-8 to the browser" do
      assert FieldValue.text_dir("abc" <> <<0xFF>>) == "auto"
      assert FieldValue.text_dir("12" <> <<0xFF>>) == "auto"
    end

    # A related record reads as its label, in the label's own direction.
    test "a related record's label reads in its own direction" do
      for {name, dir} <- [{"+20 100 123 4567", "ltr"}, {"Acme Inc.", "auto"}] do
        html =
          render_component(&FieldValue.field_value/1,
            value:
              struct(AshQuick.Test.Activation.Activated, id: Ash.UUID.generate(), name: name),
            path: [],
            ash_field: nil
          )

        assert html =~ ~s(<span dir="#{dir}">#{name}</span>)
      end
    end

    # An unloaded relationship has no text to direct, so its empty span stays
    # bare.
    test "an unloaded relationship draws no dir" do
      html =
        render_component(&FieldValue.field_value/1,
          value: %Ash.NotLoaded{type: :relationship, field: :brand},
          path: [],
          ash_field: nil
        )

      refute html =~ "dir="
    end

    test "a long text reads in its own direction" do
      for {value, dir} <- [{"Ships on Monday.", "auto"}, {"+20 100 123 4567", "ltr"}] do
        html =
          render_component(&FieldValue.field_value/1,
            value: value,
            path: [],
            ash_field: %{type: AshQuick.AshTypes.Text}
          )

        assert html =~ ~s(<span dir="#{dir}">#{value}</span></p>)
      end
    end

    test "Yes and No read in the page's direction" do
      html =
        render_component(&FieldValue.field_value/1,
          value: true,
          path: [],
          ash_field: %{type: Ash.Type.Boolean}
        )

      refute html =~ "dir="
    end
  end

  describe "field_value/1 on lists" do
    # Each item's text, as a badge of its own.
    defp items(value, type) do
      html =
        render_component(&FieldValue.field_value/1,
          value: value,
          path: [],
          ash_field: %{type: {:array, type}}
        )

      document = LazyHTML.from_fragment(html)
      list = LazyHTML.query(document, "[role=list]")

      {Enum.count(list), LazyHTML.text(list),
       document
       |> LazyHTML.query("[role=list] > [role=listitem].badge")
       |> Enum.map(&String.trim(LazyHTML.text(&1)))}
    end

    # Only space stands between two items: a comma, a dash or a semicolon
    # could be read as part of a value, or as an export's separator.
    test "shows each word as a badge, with only space between them" do
      assert {1, text, ["red", "green", "blue"]} =
               items(["red", "green", "blue"], Ash.Type.String)

      assert String.split(text) == ["red", "green", "blue"]
    end

    test "shows each number as a badge, a minus and a grouping kept to its own" do
      assert {1, text, ["-1,000", "-3"]} = items([-1_000, -3], Ash.Type.Integer)
      assert String.split(text) == ["-1,000", "-3"]

      assert {1, _, ["1.50", "-2"]} =
               items([Decimal.new("1.50"), Decimal.new("-2")], Ash.Type.Decimal)
    end

    test "an empty list renders nothing" do
      html =
        render_component(&FieldValue.field_value/1,
          value: [],
          path: [],
          ash_field: %{type: {:array, Ash.Type.String}}
        )

      assert String.trim(html) == ""
    end

    test "a single value is a single badge" do
      assert {1, _, ["-5"]} = items([-5], Ash.Type.Integer)
    end
  end

  describe "a sensitive field" do
    # Asked before any clause that would format the value, so a date, a number
    # or a list reads as redacted as a string does.
    test "is redacted whatever it holds" do
      for value <- ["4321", ~D[2026-10-19], 42, ["a", "b"], true] do
        html =
          render_component(&FieldValue.field_value/1,
            value: value,
            path: [],
            ash_field: %{sensitive?: true, type: Ash.Type.String}
          )

        assert html =~ "********"
        refute html =~ "4321"
        refute html =~ "2026"
        refute html =~ "Oct"
        refute html =~ "42"
        refute html =~ "Yes"
      end
    end

    test "is blank when it holds nothing" do
      html =
        render_component(&FieldValue.field_value/1,
          value: nil,
          path: [],
          ash_field: %{sensitive?: true, type: Ash.Type.String}
        )

      refute html =~ "*"
    end
  end
end
