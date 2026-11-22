defmodule ExampleWeb.FormStateScenarioTest do
  @moduledoc """
  A QuickView's `adjust_form/2` shapes its form from what is typed into it,
  through `AshQuick.FormState`, and the server takes only what the shape it
  builds from each post shows.

  `Example.Test.ShapedOrdersLive.Quick` shows a discount's reason, and
  requires it, only for a discount, a gift's note only for a gift, and an
  update's code read-only.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  alias Example.Test.ShapedOrders
  alias Example.Test.ShapedOrders.{Customer, Tag}
  alias Example.Test.ShapedOrdersLive.Quick, as: ShapedOrdersLive
  alias Example.Uploads.FileObject

  @form "form[phx-submit=save]"
  @upload "form[photo]_upload"
  @jpeg File.read!("priv/static/favicon.ico")

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  describe "a hidden field" do
    test "is not drawn until what shows it is picked", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_orders/create")

      refute has_input?(view, "discount_reason")
      refute has_input?(view, "gift_note")

      change(view, %{"code" => unique("O"), "kind" => "discount"}, "kind")
      assert has_input?(view, "discount_reason")
      refute has_input?(view, "gift_note")

      change(view, %{"kind" => "gift"}, "kind")
      refute has_input?(view, "discount_reason")
      assert has_input?(view, "gift_note")
      assert render(view) =~ ShapedOrdersLive.gift_help()
    end

    test "is dropped from a hand-made post that names it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_orders/create")
      code = unique("O")

      # Nothing on the page posts a reason for a standard order.
      push_change(view, %{"code" => code, "kind" => "standard", "discount_reason" => "Forged"})
      refute has_input?(view, "discount_reason")

      push_submit(view, %{
        "code" => code,
        "kind" => "standard",
        "discount_reason" => "Forged",
        "gift_note" => "Forged too"
      })

      assert %{kind: :standard, discount_reason: nil, gift_note: nil} = order(code)
    end

    test "is taken with the value that shows it, in the same post", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_orders/create")
      code = unique("O")

      # The page drew a standard order, which has no reason. The post itself
      # says discount, and the state built from it shows the reason.
      push_submit(view, %{"code" => code, "kind" => "discount", "discount_reason" => "Loyal"})

      assert %{kind: :discount, discount_reason: "Loyal"} = order(code)
    end

    test "keeps the record's value on an update", %{conn: conn} do
      record = create(kind: :gift, gift_note: "Happy birthday")
      {:ok, view, _html} = live(conn, "/test/shaped_orders/#{record.id}/update")

      assert has_input?(view, "gift_note")

      push_submit(view, %{"kind" => "standard", "gift_note" => "Overwritten"})

      assert %{kind: :standard, gift_note: "Happy birthday"} = order(record.code)
    end

    test "is cleared on an update by a change in the resource", %{conn: conn} do
      record = create(kind: :discount, discount_reason: "Loyal")
      {:ok, view, _html} = live(conn, "/test/shaped_orders/#{record.id}/update")

      change(view, %{"kind" => "standard"}, "kind")
      refute has_input?(view, "discount_reason")
      view |> form(@form) |> render_submit()

      assert %{kind: :standard, discount_reason: nil} = order(record.code)
    end
  end

  describe "a required field" do
    test "refuses a blank save with an error under it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_orders/create")
      code = unique("O")

      change(view, %{"code" => code, "kind" => "discount"}, "kind")
      assert view |> element("input[name='form[discount_reason]'][required]") |> has_element?()

      html = view |> form(@form, %{"form" => %{"discount_reason" => ""}}) |> render_submit()

      assert errors(view, "discount_reason") == ["is required"]
      assert html =~ "is required"
      assert order(code) == nil

      view |> form(@form, %{"form" => %{"discount_reason" => "Loyal"}}) |> render_submit()

      assert %{discount_reason: "Loyal"} = order(code)
    end

    test "keeps its error through a later change, as a field Ash requires does", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_orders/create")

      change(view, %{"code" => unique("O"), "kind" => "discount"}, "kind")
      view |> form(@form, %{"form" => %{"discount_reason" => ""}}) |> render_submit()
      assert errors(view, "discount_reason") == ["is required"]

      change(view, %{"code" => ""}, "code")

      assert errors(view, "code") == ["is required"]
      assert errors(view, "discount_reason") == ["is required"]

      change(view, %{"discount_reason" => "Loyal"}, "discount_reason")
      assert errors(view, "discount_reason") == []
    end

    test "stays required when the hook says otherwise", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_orders/create")

      assert view |> element("input[name='form[code]'][required]") |> has_element?()
      assert view |> element("input[name='form[code]'][placeholder='ORD-1']") |> has_element?()
    end
  end

  describe "an error Ash files under a held field" do
    test "is flashed when the field is hidden", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_orders/create")
      code = unique("O")

      change(view, %{"code" => code, "kind" => "sample"}, "kind")
      refute has_input?(view, "code")

      html = view |> form(@form) |> render_submit()

      assert order(code) == nil
      assert flash_text(html) =~ "Code: is required"
    end

    test "is flashed when the field is disabled, and when hidden on an update", %{conn: conn} do
      record = create(kind: :gift, gift_note: "Happy birthday")
      {:ok, view, _html} = live(conn, "/test/shaped_orders/#{record.id}/update")

      change(view, %{"kind" => "sample"}, "kind")
      assert held_fields(view).disabled |> Enum.member?("code")
      refute has_input?(view, "gift_note")

      html = view |> form(@form) |> render_submit()

      assert %{kind: :gift} = order(record.code)
      assert flash_text(html) =~ "Code: must be absent"
      assert flash_text(html) =~ "Gift Note: must be absent"
    end
  end

  describe "a field drawn by a type's input" do
    test "takes the label, attributes and requirement the hook gives it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_orders/create")
      amount = "input[name='form[price][amount]']"

      assert view |> element("[data-money-input] label", "Total") |> has_element?()
      assert view |> element("#{amount}[placeholder='0.00']") |> has_element?()
      refute view |> element("#{amount}[required]") |> has_element?()

      change(view, %{"code" => ShapedOrdersLive.priced_code()}, "code")
      assert view |> element("#{amount}[required]") |> has_element?()
      assert view |> element("[data-money-input] .text-error", "*") |> has_element?()
    end
  end

  describe "a disabled field" do
    test "shows its value read-only and keeps it", %{conn: conn} do
      record = create(kind: :standard)
      {:ok, view, _html} = live(conn, "/test/shaped_orders/#{record.id}/update")

      refute has_input?(view, "code")

      assert view
             |> element("[data-disabled-field='code']", record.code)
             |> has_element?()

      push_submit(view, %{"code" => "Changed", "kind" => "gift", "gift_note" => "Hi"})

      assert %{kind: :gift, gift_note: "Hi"} = order(record.code)
      assert order("Changed") == nil
    end
  end

  # AshPhoenix reads a sub-form's key that is touched and missing from the
  # params as "emptied": the server has to untouch it, not only drop it, or an
  # update saves `[]` over the record's rows.
  describe "a sub-form field" do
    test "hidden on an update keeps the record's rows", %{conn: conn} do
      record = create(kind: :standard, lines: [%{name: "Kept"}])
      {:ok, view, _html} = live(conn, "/test/shaped_orders/#{record.id}/update")

      refute has_input?(view, "lines")
      view |> form(@form) |> render_submit()

      assert line_names(record.code) == ["Kept"]
    end

    test "hidden while shown on an update keeps the record's rows", %{conn: conn} do
      record = create(kind: :bundle, lines: [%{name: "Kept"}])
      {:ok, view, _html} = live(conn, "/test/shaped_orders/#{record.id}/update")

      assert has_input?(view, "lines")
      change(view, %{"kind" => "standard"}, "kind")
      refute has_input?(view, "lines")
      view |> form(@form) |> render_submit()

      assert %{kind: :standard} = order(record.code)
      assert line_names(record.code) == ["Kept"]
    end

    test "hidden and shown again draws and keeps the record's rows", %{conn: conn} do
      record = create(kind: :bundle, lines: [%{name: "Kept"}])
      {:ok, view, _html} = live(conn, "/test/shaped_orders/#{record.id}/update")

      change(view, %{"kind" => "standard"}, "kind")
      change(view, %{"kind" => "bundle"}, "kind")

      assert view |> element("input[name='form[lines][0][name]'][value='Kept']") |> has_element?()
      view |> form(@form) |> render_submit()

      assert line_names(record.code) == ["Kept"]
    end

    test "disabled on an update keeps the record's rows, posted or not", %{conn: conn} do
      record = create(kind: :gift, lines: [%{name: "Kept"}])
      {:ok, view, _html} = live(conn, "/test/shaped_orders/#{record.id}/update")

      refute has_input?(view, "lines")
      assert view |> element("[data-disabled-field='lines']", "Kept") |> has_element?()

      push_submit(view, %{"kind" => "gift", "lines" => %{"0" => %{"name" => "Forged"}}})
      assert line_names(record.code) == ["Kept"]

      {:ok, view, _html} = live(conn, "/test/shaped_orders/#{record.id}/update")
      view |> form(@form) |> render_submit()
      assert line_names(record.code) == ["Kept"]
    end

    test "disabled and made editable again keeps the record's rows", %{conn: conn} do
      record = create(kind: :gift, lines: [%{name: "Kept"}])
      {:ok, view, _html} = live(conn, "/test/shaped_orders/#{record.id}/update")

      change(view, %{"kind" => "bundle"}, "kind")

      assert view |> element("input[name='form[lines][0][name]'][value='Kept']") |> has_element?()
      view |> form(@form) |> render_submit()

      assert %{kind: :bundle} = order(record.code)
      assert line_names(record.code) == ["Kept"]
    end
  end

  # The hook names each by the field's name; what is posted is its input:
  # `customer_id` for the `belongs_to`, the argument's own name otherwise.
  describe "a relationship or argument field" do
    setup do
      customer = Ash.create!(Customer, %{name: unique("Customer")}, authorize?: false)
      tag = Ash.create!(Tag, %{name: unique("Tag")}, authorize?: false)
      {:ok, customer: customer, tag: tag}
    end

    test "is taken while shown", %{conn: conn, customer: customer, tag: tag} do
      {:ok, view, _html} = live(conn, "/test/shaped_orders/create")
      code = unique("O")

      assert has_input?(view, "customer_id")
      assert has_picker?(view, "tag_ids")
      assert has_input?(view, "rush")

      push_submit(view, %{
        "code" => code,
        "kind" => "standard",
        "customer_id" => customer.id,
        "tag_ids" => [tag.id],
        "rush" => "true"
      })

      assert %{customer_id: customer_id, rushed: true} = order(code)
      assert customer_id == customer.id
      assert tag_ids(code) == [tag.id]
    end

    test "hidden, is not drawn and its post is dropped", ctx do
      %{conn: conn, customer: customer, tag: tag} = ctx
      {:ok, view, _html} = live(conn, "/test/shaped_orders/create")
      code = unique("O")

      change(view, %{"code" => code, "kind" => "discount"}, "kind")
      refute has_input?(view, "customer_id")
      refute has_picker?(view, "tag_ids")
      refute has_input?(view, "rush")

      push_submit(view, %{
        "code" => code,
        "kind" => "discount",
        "discount_reason" => "Loyal",
        "customer_id" => customer.id,
        "tag_ids" => [tag.id],
        "rush" => "true"
      })

      assert %{customer_id: nil, rushed: nil} = order(code)
      assert tag_ids(code) == []
    end
  end

  # A file is in the store the moment it is picked, before any save, so a
  # field the state holds back has to refuse it at the door. The create page
  # draws a stray file input for the photo whatever the state says.
  describe "an attachment field" do
    test "shown, gets an upload target", %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(conn, "/test/shaped_orders/create")
      change(view, %{"code" => unique("O"), "kind" => "gift"}, "kind")

      name = unique("shown") <> ".jpg"
      view |> pick_photo(@form, name) |> render_upload(name)

      assert name in stored_names(admin)
    end

    test "hidden, gets no upload target", %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(conn, "/test/shaped_orders/create")
      change(view, %{"code" => unique("O"), "kind" => "standard"}, "kind")
      refute has_input?(view, "photo")

      name = unique("held") <> ".jpg"
      view |> pick_photo("#stray-photo", name) |> render_upload(name)

      refute name in stored_names(admin)
    end
  end

  describe "a widget" do
    test "is drawn from its field's entry in the state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_orders/create")
      change(view, %{"code" => unique("O"), "kind" => "gift"}, "kind")

      assert view |> element("[data-widget=gift_note] label", "Card note") |> has_element?()

      assert view
             |> element("[data-widget=gift_note]", ShapedOrdersLive.gift_help())
             |> has_element?()
    end
  end

  describe "a custom action template" do
    test "reads the state the page holds", %{conn: conn} do
      record = create(kind: :gift)
      {:ok, view, _html} = live(conn, "/test/shaped_orders/#{record.id}/update")

      assert held_fields(view) == %{
               hidden: ~w(discount_reason),
               disabled: ~w(code lines)
             }

      change(view, %{"kind" => "discount"}, "kind")

      assert held_fields(view) == %{
               hidden: ~w(gift_note lines customer photo tag_ids rush),
               disabled: ~w(code)
             }
    end
  end

  describe "a field Ash leaves out" do
    test "is not drawn or taken, whatever the hook puts in the state", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_orders/create")
      code = unique("O")

      refute has_input?(view, "locked_code")
      refute render(view) =~ "Locked code"

      push_submit(view, %{"code" => code, "kind" => "standard", "locked_code" => "Forged"})

      assert %{locked_code: nil} = order(code)
    end
  end

  describe "after a reconnect" do
    # LiveView mounts again and replays the form with what the page holds.
    # Nothing of the state survives the old process, and nothing has to: it
    # is built again from the form, which the replay fills back in.
    test "the form comes back with the same shape and values", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_orders/create")
      code = unique("O")

      change(view, %{"code" => code, "kind" => "discount"}, "kind")
      change(view, %{"discount_reason" => "Loyal"}, "discount_reason")
      held = page_params(view)
      assert held["discount_reason"] == "Loyal"

      {:ok, view, _html} = live(conn, "/test/shaped_orders/create")
      refute has_input?(view, "discount_reason")

      render_change(view, "validate", %{"form" => held})

      assert view
             |> element("input[name='form[discount_reason]'][value='Loyal']")
             |> has_element?()

      view |> form(@form) |> render_submit()

      assert %{kind: :discount, discount_reason: "Loyal"} = order(code)
    end
  end

  defp create(attrs) do
    Ash.create!(ShapedOrders, Map.new(attrs) |> Map.put(:code, unique("O")), authorize?: false)
  end

  defp line_names(code), do: Enum.map(order(code).lines, & &1.name)

  defp tag_ids(code),
    do:
      order(code) |> Ash.load!(:tags, authorize?: false) |> Map.fetch!(:tags) |> Enum.map(& &1.id)

  defp pick_photo(view, form, name) do
    file_input(view, form, @upload, [
      %{name: name, content: @jpeg, type: "image/jpeg", size: byte_size(@jpeg)}
    ])
  end

  defp stored_names(actor) do
    FileObject
    |> Ash.read!(actor: actor, authorize?: false)
    |> Enum.map(& &1.original_filename)
  end

  defp held_fields(view) do
    [node] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#held-fields")
      |> Enum.to_list()

    %{
      hidden: node |> attribute("data-hidden") |> String.split(),
      disabled: node |> attribute("data-disabled") |> String.split()
    }
  end

  defp order(code) do
    ShapedOrders
    |> Ash.Query.filter(code == ^code)
    |> Ash.read_one!(authorize?: false)
  end

  defp has_input?(view, name),
    do: view |> element("#{@form} [name^='form[#{name}]']") |> has_element?()

  # A many-to-many picker posts its inputs as `form[name_text_input]` and the like.
  defp has_picker?(view, name),
    do: view |> element("#{@form} [name^='form[#{name}_']") |> has_element?()

  # A change to one input, posted with what the rest of the page holds.
  defp change(view, params, target) do
    view
    |> form(@form)
    |> render_change(%{"form" => params, "_target" => ["form", target]})
  end

  # Posts made exactly as given, whatever the page draws.
  defp push_change(view, params), do: render_change(view, "validate", %{"form" => params})
  defp push_submit(view, params), do: render_submit(view, "save", %{"form" => params})

  # What the page's form posts: every named input it renders.
  defp page_params(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{@form} input[name]:not([type=file])")
    |> Enum.map(&{attribute(&1, "name"), attribute(&1, "value") || ""})
    |> URI.encode_query()
    |> Plug.Conn.Query.decode()
    |> Map.fetch!("form")
  end

  defp attribute(node, name), do: node |> LazyHTML.attribute(name) |> List.first()

  defp flash_text(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#flash-error")
    |> LazyHTML.text()
  end

  defp errors(view, field) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{@form} [id$='_#{field}-errors'] p")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
