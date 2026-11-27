defmodule ExampleWeb.PickerFiltersScenarioTest do
  @moduledoc """
  A QuickView's `adjust_form/2` narrows what a form's pickers offer, through
  `AshQuick.FormState.filter/3` and `options/3`. They shape the page only:
  the save takes what is posted, and leaves rules to the resource.

  `Example.Test.PickedPlacesLive.Quick` offers only the picked country's
  cities, as the city and as stops, only draft and submitted as the status,
  and only the ship for each leg of a cruise. The port's relationship
  filters to ports.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  alias Example.Test.PickedPlaces
  alias Example.Test.PickedPlaces.{City, Country, Label, Owner}
  alias ExampleWeb.PickerDriver

  @form "form[phx-submit=save]"

  setup %{conn: conn, admin: admin} do
    egypt = country("Egypt")
    italy = country("Italy")

    {:ok,
     conn: log_in(conn, admin),
     egypt: egypt,
     italy: italy,
     cairo: city("Cairo", egypt),
     alex: city("Alexandria", egypt, port?: true),
     rome: city("Rome", italy),
     genoa: city("Genoa", italy, port?: true)}
  end

  describe "a picker narrowed by filter/3" do
    test "offers only what the filter keeps", ctx do
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")
      pick_country(view, ctx.egypt)

      assert PickerDriver.search(view, "form_city_id-picker") |> Enum.sort() ==
               Enum.sort([ctx.cairo.name, ctx.alex.name])

      pick_country(view, ctx.italy)

      assert PickerDriver.search(view, "form_city_id-picker", "") |> Enum.sort() ==
               Enum.sort([ctx.rome.name, ctx.genoa.name])
    end

    test "searches again when it changes under a list it already searched", ctx do
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")
      pick_country(view, ctx.egypt)
      PickerDriver.search(view, "form_city_id-picker")

      # The list stays open: the country changes, and the list follows it
      # with no search of the person's own.
      pick_country(view, ctx.italy)
      render_async(view)

      assert PickerDriver.offered(view, "form_city_id-picker") |> Enum.sort() ==
               Enum.sort([ctx.rome.name, ctx.genoa.name])
    end

    test "keeps a pick the new filter leaves out, and the save takes it", ctx do
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")
      code = unique("T")
      change(view, %{"code" => code}, "code")
      pick_country(view, ctx.egypt)
      PickerDriver.search(view, "form_city_id-picker", ctx.cairo.name)
      PickerDriver.pick(view, "form_city_id-picker", ctx.cairo.name)

      pick_country(view, ctx.italy)

      # Kept, under its own label, not cleared behind the person's back.
      assert PickerDriver.picked(view, "form_city_id-picker") == [ctx.cairo.name]

      view |> form(@form) |> render_submit()

      assert %{country_id: italy, city_id: cairo} = trip(code)
      assert {italy, cairo} == {ctx.italy.id, ctx.cairo.id}
    end
  end

  describe "an inactive record" do
    setup %{italy: italy} do
      closed = city("Closed", italy, port?: true)
      {:ok, closed: Ash.update!(closed, %{}, action: :deactivate, authorize?: false)}
    end

    test "that an update's record holds is kept", ctx do
      record = create(port_id: ctx.closed.id)
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/#{record.id}/update")

      view |> form(@form) |> render_submit(%{"form" => %{"kind" => "cruise"}})

      assert %{kind: :cruise, port_id: closed} = trip(record.code)
      assert closed == ctx.closed.id
    end
  end

  describe "a belongs_to a widget draws" do
    # Its destination has no lookup action, which the page asks nothing of.
    test "saves what the widget posts", ctx do
      owner = Ash.create!(Owner, %{name: unique("Owner")}, authorize?: false)
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")
      code = unique("T")

      assert has_element?(view, "#{@form} [data-owner-widget]")

      view
      |> form(@form, form: %{code: code, owner_id: owner.id})
      |> render_submit()

      assert trip(code).owner_id == owner.id
    end
  end

  describe "a list picker narrowed by filter/3" do
    test "offers only what the filter keeps", ctx do
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")
      pick_country(view, ctx.italy)

      assert PickerDriver.search(view, "form_stop_ids-picker") |> Enum.sort() ==
               Enum.sort([ctx.rome.name, ctx.genoa.name])
    end
  end

  describe "a list picker that creates names no label holds" do
    setup do
      {:ok,
       open: label("Open"),
       archived: label("Archived", archived?: true),
       restricted: label("Restricted", restricted?: true)}
    end

    test "offers neither the labels its lookup hides nor those the hook leaves out", ctx do
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")

      # The lookup takes no notice of the search, and the labels of other
      # tests share the table: each label is looked for among the offered.
      assert ctx.open.name in PickerDriver.search(view, "form_labels-picker", ctx.open.name)

      refute ctx.archived.name in PickerDriver.search(
               view,
               "form_labels-picker",
               ctx.archived.name
             )

      refute ctx.restricted.name in PickerDriver.search(
               view,
               "form_labels-picker",
               ctx.restricted.name
             )
    end
  end

  describe "a relationship's own filter" do
    test "leaves alone what an update's record already holds", ctx do
      # Stored outside the filter: the save does not change it.
      record = create(port_id: ctx.rome.id)
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/#{record.id}/update")

      view |> form(@form) |> render_submit(%{"form" => %{"kind" => "cruise"}})

      assert %{kind: :cruise, port_id: rome} = trip(record.code)
      assert rome == ctx.rome.id
    end
  end

  describe "a choice narrowed by options/3" do
    test "offers only those options", ctx do
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")

      assert PickerDriver.search(view, "form_status-picker") == ["Draft", "Submitted"]
    end

    test "draws the value an update's record holds outside them, and keeps it", ctx do
      record = create(status: :approved)
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/#{record.id}/update")

      # Still drawn as what the field holds, but no longer offered.
      assert PickerDriver.picked(view, "form_status-picker") == ["Approved"]
      assert PickerDriver.search(view, "form_status-picker") == ["Draft", "Submitted"]

      view |> form(@form) |> render_submit()
      assert trip(record.code).status == :approved
    end

    test "narrows a sub-form's row by its parent's value", ctx do
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")
      code = unique("T")

      view
      |> element("#{@form} [phx-click=add-form][phx-value-path='form[legs]']")
      |> render_click()

      change(view, %{"code" => code, "kind" => "cruise"}, "kind")

      assert PickerDriver.search(view, "form_legs_0_mode-picker") == ["Ship"]
    end
  end

  defp country(name),
    do: Ash.create!(Country, %{name: unique(name)}, authorize?: false)

  defp city(name, country, attrs \\ []) do
    Ash.create!(
      City,
      Map.merge(%{name: unique(name), country_id: country.id}, Map.new(attrs)),
      authorize?: false
    )
  end

  # The label, its `ci_string` name as plain text.
  defp label(name, attrs \\ []) do
    label =
      Ash.create!(Label, Map.merge(%{name: unique(name)}, Map.new(attrs)), authorize?: false)

    %{label | name: to_string(label.name)}
  end

  defp create(attrs) do
    Ash.create!(PickedPlaces, attrs |> Map.new() |> Map.put(:code, unique("T")),
      authorize?: false
    )
  end

  defp trip(code) do
    PickedPlaces
    |> Ash.Query.filter(code == ^code)
    |> Ash.read_one!(authorize?: false)
  end

  defp pick_country(view, country) do
    PickerDriver.search(view, "form_country_id-picker", country.name)
    PickerDriver.pick(view, "form_country_id-picker", country.name)
  end

  # A change to one input, posted with what the rest of the page holds.
  defp change(view, params, target) do
    view
    |> form(@form)
    |> render_change(%{"form" => params, "_target" => ["form", target]})
  end
end
