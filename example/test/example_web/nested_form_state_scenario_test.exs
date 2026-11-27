defmodule ExampleWeb.NestedFormStateScenarioTest do
  @moduledoc """
  A QuickView's `adjust_form/2` shapes each sub-form from what is typed into
  it, through `AshQuick.FormState.update_each/3`. Each row is drawn from its
  own state, and a field a stored row holds back keeps the row's value.

  `Example.Test.ShapedBundlesLive.Quick` shows an item's serial, drawn
  required, only for a device, its hours only for a service, its parts
  only for a device, and its discount read-only unless the bundle is sold
  wholesale. A shipping address shows its region only for the US, and is
  hidden for a wholesale bundle.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  alias Example.Test.ShapedBundles
  alias Example.Test.ShapedBundlesLive.Quick, as: ShapedBundlesLive

  @form "form[phx-submit=save]"

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  describe "a row's hidden field" do
    test "is drawn only on the rows whose values show it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/create")
      add_item(view)
      add_item(view)

      refute has_input?(view, "items][0][serial")
      refute has_input?(view, "items][1][hours")

      change(view, %{"code" => unique("B"), "items" => items(["device", "service"])}, "kind")

      assert has_input?(view, "items][0][serial")
      refute has_input?(view, "items][0][hours")
      refute has_input?(view, "items][1][serial")
      assert has_input?(view, "items][1][hours")
    end

    test "follows its row when a row above it is removed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/create")
      add_item(view)
      add_item(view)
      change(view, %{"code" => unique("B"), "items" => items(["device", "good"])}, "kind")
      assert has_input?(view, "items][0][serial")

      remove_item(view, 0)

      # The good item is the first row now, and it has no serial.
      refute has_input?(view, "items][0][serial")
      refute has_input?(view, "items][1")

      add_item(view)
      change(view, %{"items" => items(["good", "device"])}, "kind")
      remove_item(view, 0)

      # And the device moved up keeps its serial.
      assert has_input?(view, "items][0][serial")
    end

    # A stored embed row is saved whole: the server posts a held field's
    # stored value for it, as the page draws no input for it.
    test "keeps the stored row's value on an update", %{conn: conn} do
      record = create(items: [%{kind: :device, serial: "SN-1"}, %{kind: :service, hours: 3}])
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")

      assert has_input?(view, "items][0][serial")

      change(
        view,
        %{
          "items" => %{"0" => %{"kind" => "good"}, "1" => %{"kind" => "service", "hours" => "5"}}
        },
        "kind"
      )

      refute has_input?(view, "items][0][serial")
      view |> form(@form) |> render_submit()

      assert [%{kind: :good, serial: "SN-1"}, %{kind: :service, hours: 5}] =
               bundle(record.code).items
    end
  end

  describe "a hand-made post keyed past the rows' numbers" do
    # The discount is read-only on a retail bundle: held to the stored one
    # at the row's place.
    test "a stored row left out of a change, then save", %{conn: conn} do
      record = create(items: [%{kind: :good, discount: 5}, %{kind: :good, discount: 9}])
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")

      move(view, %{"items" => %{"1" => %{"kind" => "good", "discount" => "1"}}})
      refute has_input?(view, "items][1")
      view |> form(@form) |> render_submit()

      assert [%{kind: :good, discount: 5}] = bundle(record.code).items
    end
  end

  describe "a template's remove and reorder inputs" do
    # AshPhoenix's own `_drop_` and `_sort_` inputs, as a custom template
    # could draw them, are applied.
    test "drop a row", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/create")
      code = unique("B")
      add_item(view)
      add_item(view)

      push_submit(view, %{
        "code" => code,
        "_drop_items" => ["0"],
        "items" => %{
          "0" => %{"kind" => "good", "serial" => "Forged"},
          "1" => %{"kind" => "device", "serial" => "SN-12"}
        }
      })

      assert [%{kind: :device, serial: "SN-12"}] = bundle(code).items
    end

    # On an update the page posts only what it draws: the discount is
    # read-only on a retail bundle, so each stored row posts none, and the
    # row these inputs move keeps its own stored discount.
    test "drop a stored row", %{conn: conn} do
      record = create(items: [%{kind: :good, discount: 5}, %{kind: :good, discount: 9}])
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")

      push_submit(view, %{
        "_drop_items" => ["0"],
        "items" => %{"0" => %{"kind" => "good"}, "1" => %{"kind" => "good"}}
      })

      assert [%{kind: :good, discount: 9}] = bundle(record.code).items
    end

    test "reorder stored rows", %{conn: conn} do
      record = create(items: [%{kind: :good, discount: 5}, %{kind: :good, discount: 9}])
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")

      push_submit(view, %{
        "_sort_items" => ["1", "0"],
        "items" => %{"0" => %{"kind" => "good"}, "1" => %{"kind" => "good"}}
      })

      assert [%{discount: 9}, %{discount: 5}] = bundle(record.code).items
    end

    test "add a row above stored rows", %{conn: conn} do
      record = create(items: [%{kind: :good, discount: 5}])
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")

      push_submit(view, %{
        "_add_items" => "start",
        "items" => %{"0" => %{"kind" => "good"}}
      })

      assert [%{kind: :good, discount: nil}, %{kind: :good, discount: 5}] =
               bundle(record.code).items
    end

    # Moved on a change, a row's own sub-forms move with it, so the page
    # draws them under the row's new place and the save keeps them with it.
    test "reorder stored rows on a change, then save", %{conn: conn} do
      record = two_devices()
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")

      move(view, %{"_sort_items" => ["1", "0"], "items" => two_devices_posted()})
      view |> form(@form) |> render_submit()

      assert [
               %{serial: "SN-B", parts: [%{name: "pb"}], spec: %{watts: 7}},
               %{serial: "SN-A", parts: [%{name: "pa"}], spec: %{watts: 5}}
             ] = bundle(record.code).items
    end

    test "drop a stored row on a change, then save", %{conn: conn} do
      record = two_devices()
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")

      move(view, %{"_drop_items" => ["0"], "items" => two_devices_posted()})
      assert has_input?(view, "items][0][parts][0][name")
      refute has_input?(view, "items][1")
      view |> form(@form) |> render_submit()

      assert [%{serial: "SN-B", parts: [%{name: "pb"}], spec: %{watts: 7}}] =
               bundle(record.code).items
    end
  end

  describe "a hidden single sub-form the record holds none of" do
    test "stays empty on a row", %{conn: conn} do
      record = create(items: [%{kind: :good}])
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")

      view |> form(@form) |> render_submit()

      assert [%{kind: :good, spec: nil}] = bundle(record.code).items
    end

    test "stays empty at the root", %{conn: conn} do
      record = create(channel: :wholesale)
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")

      refute has_input?(view, "shipping]")
      view |> form(@form) |> render_submit()

      assert %{channel: :wholesale, shipping: nil} = bundle(record.code)

      record = create(channel: :retail)
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")

      assert has_input?(view, "shipping][country")
      change(view, %{"channel" => "wholesale"}, "channel")
      view |> form(@form) |> render_submit()

      assert %{channel: :wholesale, shipping: nil} = bundle(record.code)
    end

    test "keeps a stored one on a row that hides it", %{conn: conn} do
      record = create(items: [%{kind: :device, serial: "SN-10", spec: %{watts: 5}}])
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")

      change(view, %{"items" => %{"0" => %{"kind" => "good"}}}, "kind")
      view |> form(@form) |> render_submit()

      assert [%{kind: :good, spec: %{watts: 5}}] = bundle(record.code).items
    end
  end

  describe "an Ash error on a row's hidden field" do
    # A device has no hours: the stored service's hours, kept while hidden,
    # are refused, and the form has no input to show that under.
    test "is flashed with the row it is about", %{conn: conn} do
      record = create(items: [%{kind: :service, hours: 3}])
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")

      change(view, %{"items" => %{"0" => %{"kind" => "device", "serial" => "SN-11"}}}, "kind")
      html = view |> form(@form) |> render_submit()

      assert flash_text(html) =~ "Items 1 › Hours"
      assert [%{kind: :service, hours: 3}] = bundle(record.code).items
    end
  end

  describe "a stored row with no sub-form rows" do
    # Its parts post nothing at all, which the save's uploads must take as
    # no rows to upload for.
    test "saves as it is", %{conn: conn} do
      record = create(items: [%{kind: :device, serial: "SN-6"}])
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")

      view |> form(@form) |> render_submit()

      assert [%{kind: :device, serial: "SN-6", parts: []}] = bundle(record.code).items
    end

    test "saves once its last part is removed", %{conn: conn} do
      record = create(items: [%{kind: :device, serial: "SN-7", parts: [%{name: "Fan"}]}])
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")

      view
      |> element("#{@form} [phx-click=remove-form][phx-value-path='form[items][0][parts][0]']")
      |> render_click()

      view |> form(@form) |> render_submit()

      assert [%{serial: "SN-7", parts: []}] = bundle(record.code).items
    end

    test "draws a required field it shows required", %{conn: conn} do
      record = create(items: [%{kind: :good}])
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")

      change(view, %{"items" => %{"0" => %{"kind" => "device"}}}, "kind")

      assert view
             |> element("#{@form} input[name='form[items][0][serial]'][required]")
             |> has_element?()
    end
  end

  describe "a row's required field" do
    test "is drawn required on the rows that show it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/create")
      code = unique("B")
      add_item(view)
      change(view, %{"code" => code, "items" => items(["device"])}, "kind")

      assert view
             |> element("#{@form} input[name='form[items][0][serial]'][required]")
             |> has_element?()

      change(view, %{"items" => %{"0" => %{"kind" => "device", "serial" => "SN-2"}}}, "serial")
      view |> form(@form) |> render_submit()

      assert [%{kind: :device, serial: "SN-2"}] = bundle(code).items
    end

    test "is not asked for on a row that hides it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/create")
      code = unique("B")
      add_item(view)
      change(view, %{"code" => code, "items" => items(["good"])}, "kind")

      view |> form(@form) |> render_submit()

      assert [%{kind: :good}] = bundle(code).items
    end
  end

  describe "a row reading its parent" do
    test "draws its discount read-only unless the bundle is wholesale", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/create")
      add_item(view)

      refute has_input?(view, "items][0][discount")
      assert view |> element("#{@form} [data-disabled-field=discount]") |> has_element?()

      change(view, %{"code" => unique("B"), "channel" => "wholesale"}, "channel")

      assert has_input?(view, "items][0][discount")
      refute view |> element("#{@form} [data-disabled-field=discount]") |> has_element?()
    end

    test "keeps a stored row's discount on an update", %{conn: conn} do
      record = create(items: [%{kind: :good, discount: 10}])
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")

      assert view |> element("#{@form} [data-disabled-field=discount]", "10") |> has_element?()

      view |> form(@form) |> render_submit()

      assert [%{discount: 10}] = bundle(record.code).items
    end
  end

  describe "a row's sub-forms" do
    test "follow the rule two levels down", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/create")
      code = unique("B")
      add_item(view)

      refute view
             |> element("#{@form} [phx-value-path='form[items][0][parts]']")
             |> has_element?()

      change(view, %{"code" => code, "items" => items(["device"])}, "kind")
      view |> element("#{@form} [phx-value-path='form[items][0][parts]']") |> render_click()

      assert render(view) =~ ShapedBundlesLive.part_label()

      change(
        view,
        %{
          "items" => %{
            "0" => %{
              "kind" => "device",
              "serial" => "SN-3",
              "parts" => %{"0" => %{"name" => "Fan"}}
            }
          }
        },
        "name"
      )

      view |> form(@form) |> render_submit()

      assert [%{serial: "SN-3", parts: [%{name: "Fan"}]}] = bundle(code).items
    end

    # AshPhoenix reads a sub-form key it counts as touched and the params
    # lack as emptied: a row's held parts must post the stored ones.
    test "keep a stored row's parts on an update, hidden and shown again", %{conn: conn} do
      record = create(items: [%{kind: :device, serial: "SN-4", parts: [%{name: "Fan"}]}])
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")

      change(view, %{"items" => %{"0" => %{"kind" => "good"}}}, "kind")

      refute view
             |> element("#{@form} [phx-value-path='form[items][0][parts]']")
             |> has_element?()

      change(view, %{"items" => %{"0" => %{"kind" => "device"}}}, "kind")

      assert view
             |> element("#{@form} input[name='form[items][0][parts][0][name]'][value='Fan']")
             |> has_element?()

      change(view, %{"items" => %{"0" => %{"kind" => "good"}}}, "kind")
      view |> form(@form) |> render_submit()

      assert [%{kind: :good, serial: "SN-4", parts: [%{name: "Fan"}]}] =
               bundle(record.code).items
    end
  end

  describe "a single sub-form" do
    test "shows its field only for the value that shows it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/create")
      us = unique("B")
      elsewhere = unique("B")

      refute has_input?(view, "shipping][region")
      change(view, %{"code" => us, "shipping" => %{"country" => "US"}}, "country")
      assert has_input?(view, "shipping][region")

      push_submit(view, %{"code" => us, "shipping" => %{"country" => "US", "region" => "CA"}})
      assert %{country: "US", region: "CA"} = bundle(us).shipping

      {:ok, view, _html} = live(conn, "/test/shaped_bundles/create")
      change(view, %{"code" => elsewhere, "shipping" => %{"country" => "EG"}}, "country")
      refute has_input?(view, "shipping][region")
      view |> form(@form) |> render_submit()

      assert %{country: "EG", region: nil} = bundle(elsewhere).shipping
    end
  end

  # No page posts a single sub-form as text. AshPhoenix raises on it, so it
  # is left out, and the record keeps its address.
  for event <- ["validate", "save"] do
    test "a single sub-form posted as text is left out of a #{event}", %{conn: conn} do
      record = create(shipping: %{country: "US", region: "CA"})
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")

      render_change(view, unquote(event), %{
        "form" => %{"_touched" => "shipping", "shipping" => ""},
        "_target" => ["form", "shipping"]
      })

      assert render(view)
    end
  end

  describe "after a reconnect" do
    test "each row comes back with the same shape and values", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/create")
      code = unique("B")
      add_item(view)
      add_item(view)
      change(view, %{"code" => code, "items" => items(["service", "device"])}, "kind")

      change(
        view,
        %{"items" => %{"0" => %{"hours" => "2"}, "1" => %{"serial" => "SN-5"}}},
        "serial"
      )

      held = page_params(view)
      assert held["items"]["1"]["serial"] == "SN-5"

      {:ok, view, _html} = live(conn, "/test/shaped_bundles/create")
      render_change(view, "validate", %{"form" => held})

      assert view
             |> element("input[name='form[items][1][serial]'][value='SN-5']")
             |> has_element?()

      refute has_input?(view, "items][0][serial")

      view |> form(@form) |> render_submit()

      assert [%{kind: :service, hours: 2}, %{kind: :device, serial: "SN-5"}] =
               bundle(code).items
    end

    @stored_rows [
      %{kind: :good, discount: 5},
      %{kind: :device, serial: "SN-B", discount: 9, parts: [%{name: "P1"}]}
    ]

    test "a row added beside stored rows comes back as a new row", %{conn: conn} do
      record = create(items: @stored_rows)
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")
      add_item(view)
      change(view, %{"items" => %{"2" => %{"kind" => "service"}}}, "kind")
      change(view, %{"items" => %{"2" => %{"hours" => "4"}}}, "hours")
      held = page_params(view)
      assert held["items"]["2"]["_form_type"] == "create"

      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")
      render_change(view, "validate", %{"form" => held})

      assert view
             |> element("input[name='form[items][2][hours]'][value='4']")
             |> has_element?()

      view |> form(@form) |> render_submit()

      assert [
               %{kind: :good, discount: 5},
               %{kind: :device, serial: "SN-B", discount: 9, parts: [%{name: "P1"}]},
               %{kind: :service, hours: 4}
             ] = bundle(record.code).items
    end

    # A row the page added posts itself as new, and is never matched to the
    # stored row at its place: every stored row removed and one added, the
    # row that comes back holds no stored row's discount.
    test "a row added once the stored rows are removed is still a new row", %{conn: conn} do
      record = create(items: @stored_rows)
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")
      remove_item(view, 0)
      remove_item(view, 0)
      add_item(view)
      held = page_params(view)
      assert held["items"]["0"]["_form_type"] == "create"

      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")
      render_change(view, "validate", %{"form" => held})
      view |> form(@form) |> render_submit()

      assert [%{kind: :good, discount: nil, parts: []}] = bundle(record.code).items
    end

    # An embed with a public primary key posts it, so each row left after a
    # ✕ is matched to its own stored row, and keeps its own held values:
    # the device's serial, hidden once it is a good, and the discount.
    test "embed rows with a primary key keep their own stored row", %{conn: conn} do
      record =
        Ash.create!(
          Example.Test.KeyedItems,
          %{
            code: unique("K"),
            items: [%{kind: :good, discount: 5}, %{kind: :device, serial: "SN-B", discount: 9}]
          },
          authorize?: false
        )

      {:ok, view, _html} = live(conn, "/test/keyed_items/#{record.id}/update")
      remove_item(view, 0)
      held = page_params(view)
      assert map_size(held["items"]) == 1

      {:ok, view, _html} = live(conn, "/test/keyed_items/#{record.id}/update")
      render_change(view, "validate", %{"form" => held})

      assert view
             |> element("input[name='form[items][0][serial]'][value='SN-B']")
             |> has_element?()

      view |> form(@form) |> render_submit()

      assert [%{kind: :device, serial: "SN-B", discount: 9}] =
               Ash.get!(Example.Test.KeyedItems, record.id, authorize?: false).items
    end

    # A change the page sent before its ✕ landed still names the removed
    # row: AshPhoenix takes what a post names, so the row is back, drawn
    # again for the reader to remove.
    test "a change sent before a ✕ landed brings the row back", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/create")
      add_item(view)
      add_item(view)
      stale = page_params(view)
      remove_item(view, 1)
      refute has_input?(view, "items][1")

      move(view, stale)

      assert has_input?(view, "items][1")
    end

    # Known gap: rows without a primary key are matched by their place, so
    # after a reconnect that follows a ✕ the row left takes the removed
    # row's read-only discount (and, for a good after a device, its hidden
    # serial).
    @tag :skip
    test "a reconnect after a stored row was removed keeps each row's held values",
         %{conn: conn} do
      record = create(items: [%{kind: :good, discount: 5}, %{kind: :good, discount: 9}])
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")
      remove_item(view, 0)
      held = page_params(view)

      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")
      render_change(view, "validate", %{"form" => held, "_target" => ["form", "code"]})
      view |> form(@form) |> render_submit()

      assert [%{kind: :good, discount: 9}] = bundle(record.code).items
    end

    # Known gap: a list the page emptied posts nothing for it, so after a
    # reconnect its stored rows come back and are saved again.
    @tag :skip
    test "a reconnect after every stored row was removed saves no rows", %{conn: conn} do
      record = create(items: [%{kind: :good, discount: 5}, %{kind: :good, discount: 9}])
      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")
      remove_item(view, 0)
      remove_item(view, 0)
      held = page_params(view)
      refute Map.has_key?(held, "items")

      {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")
      render_change(view, "validate", %{"form" => held, "_target" => ["form", "code"]})
      view |> form(@form) |> render_submit()

      assert [] = bundle(record.code).items
    end
  end

  defp two_devices do
    create(
      items: [
        %{kind: :device, serial: "SN-A", parts: [%{name: "pa"}], spec: %{watts: 5}},
        %{kind: :device, serial: "SN-B", parts: [%{name: "pb"}], spec: %{watts: 7}}
      ]
    )
  end

  defp two_devices_posted do
    %{
      "0" => %{
        "kind" => "device",
        "serial" => "SN-A",
        "parts" => %{"0" => %{"name" => "pa"}},
        "spec" => %{"watts" => "5"}
      },
      "1" => %{
        "kind" => "device",
        "serial" => "SN-B",
        "parts" => %{"0" => %{"name" => "pb"}},
        "spec" => %{"watts" => "7"}
      }
    }
  end

  defp move(view, params),
    do: render_change(view, "validate", %{"form" => params, "_target" => ["form", "items"]})

  defp create(attrs) do
    Ash.create!(ShapedBundles, Map.new(attrs) |> Map.put(:code, unique("B")), authorize?: false)
  end

  defp bundle(code) do
    ShapedBundles
    |> Ash.Query.filter(code == ^code)
    |> Ash.read_one!(authorize?: false)
  end

  defp items(kinds) do
    kinds
    |> Enum.with_index()
    |> Map.new(fn {kind, index} -> {to_string(index), %{"kind" => kind}} end)
  end

  defp add_item(view),
    do:
      view
      |> element("#{@form} [phx-click=add-form][phx-value-path='form[items]']")
      |> render_click()

  defp remove_item(view, index) do
    view
    |> element("#{@form} [phx-click=remove-form][phx-value-path='form[items][#{index}]']")
    |> render_click()
  end

  defp has_input?(view, name),
    do: view |> element("#{@form} [name^='form[#{name}]']") |> has_element?()

  # A change to one input, posted with what the rest of the page holds.
  defp change(view, params, target) do
    view
    |> form(@form)
    |> render_change(%{"form" => params, "_target" => ["form", target]})
  end

  defp push_submit(view, params), do: render_submit(view, "save", %{"form" => params})

  # What the page's form posts: every named input it renders.
  defp page_params(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{@form} input[name]:not([type=file]), #{@form} select[name]")
    |> Enum.map(&{attribute(&1, "name"), value(&1)})
    |> URI.encode_query()
    |> Plug.Conn.Query.decode()
    |> Map.fetch!("form")
  end

  defp value(node) do
    case node |> LazyHTML.query("option[selected]") |> Enum.to_list() do
      [option | _] -> attribute(option, "value") || ""
      [] -> attribute(node, "value") || ""
    end
  end

  defp attribute(node, name), do: node |> LazyHTML.attribute(name) |> List.first()

  defp flash_text(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#flash-error")
    |> LazyHTML.text()
  end
end
