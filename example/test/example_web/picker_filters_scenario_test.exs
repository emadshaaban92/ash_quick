defmodule ExampleWeb.PickerFiltersScenarioTest do
  @moduledoc """
  A QuickView's `adjust_form/2` narrows what a form's pickers offer, through
  `AshQuick.FormState.filter/3`, `lookup_args/3` and `options/3`, and the
  save holds what was posted to what they offer.

  `Example.Test.PickedPlacesLive.Quick` offers only the picked country's
  cities, as the city and as stops, only draft and submitted as the status,
  and only the ship for each leg of a cruise. The port's relationship
  filters to ports, which the save checks too.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  alias Example.Test.PickedPlaces
  alias Example.Test.PickedPlaces.{City, Country, Label, Owner}
  alias ExampleWeb.PickerDriver

  @form "form[phx-submit=save]"
  @not_offered "is not one of the choices offered"

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

  describe "a picker narrowed by lookup_args/3" do
    test "offers only what the lookup action reads with them", ctx do
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")
      pick_country(view, ctx.egypt)

      assert PickerDriver.search(view, "form_city_id-picker") |> Enum.sort() ==
               Enum.sort([ctx.cairo.name, ctx.alex.name])

      pick_country(view, ctx.italy)

      assert PickerDriver.search(view, "form_city_id-picker", "") |> Enum.sort() ==
               Enum.sort([ctx.rome.name, ctx.genoa.name])
    end

    test "searches again when they change under a list it already searched", ctx do
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

    test "keeps a pick the new ones leave out, and the save refuses it", ctx do
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

      assert errors(view, "city_id") == [@not_offered]
      assert trip(code) == nil

      PickerDriver.search(view, "form_city_id-picker", ctx.rome.name)
      PickerDriver.pick(view, "form_city_id-picker", ctx.rome.name)
      view |> form(@form) |> render_submit()

      assert %{country_id: italy, city_id: rome} = trip(code)
      assert {italy, rome} == {ctx.italy.id, ctx.rome.id}
    end

    test "holds a hand-made post to them", ctx do
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")
      code = unique("T")

      push_submit(view, %{
        "code" => code,
        "country_id" => ctx.egypt.id,
        "city_id" => ctx.rome.id
      })

      assert errors(view, "city_id") == [@not_offered]
      assert trip(code) == nil
    end

    test "holds the city an update keeps to the country it now has", ctx do
      record = create(country_id: ctx.egypt.id, city_id: ctx.cairo.id)
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/#{record.id}/update")

      push_submit(view, %{"code" => record.code, "country_id" => ctx.italy.id})

      assert errors(view, "city_id") == [@not_offered]
      assert trip(record.code).country_id == ctx.egypt.id
    end
  end

  describe "a refused pick" do
    test "is not read again on a later change, so its error goes until the next save", ctx do
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")
      code = unique("T")
      post = %{"code" => code, "country_id" => ctx.egypt.id, "city_id" => ctx.rome.id}

      push_submit(view, post)
      assert errors(view, "city_id") == [@not_offered]

      render_change(view, "validate", %{"form" => post, "_target" => ["form", "code"]})
      assert errors(view, "city_id") == []

      push_submit(view, post)
      assert errors(view, "city_id") == [@not_offered]
    end

    test "is read back in pages the lookup action allows", ctx do
      spain = country("Spain")
      cities = for name <- ~w(Madrid Seville Valencia), do: city(name, spain)
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")
      code = unique("T")

      # The lookup reads two cities a page: the third is read in a second.
      push_submit(view, %{
        "code" => code,
        "country_id" => spain.id,
        "stop_ids" => Enum.map(cities, & &1.id)
      })

      assert errors(view, "stop_ids") == []
      assert stop_ids(code) |> Enum.sort() == cities |> Enum.map(& &1.id) |> Enum.sort()
    end
  end

  describe "an inactive record" do
    setup %{italy: italy} do
      closed = city("Closed", italy, port?: true)
      {:ok, closed: Ash.update!(closed, %{}, action: :deactivate, authorize?: false)}
    end

    test "is refused when picked", ctx do
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")
      code = unique("T")

      push_submit(view, %{"code" => code, "port_id" => ctx.closed.id})

      assert errors(view, "port_id") == [@not_offered]
      assert trip(code) == nil
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
    # Its destination has no lookup action: the save leaves the pick to the
    # widget, as the page asks nothing of it either.
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

    test "refuses a stop the filter leaves out, and saves those it keeps", ctx do
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")
      code = unique("T")

      push_submit(view, %{
        "code" => code,
        "country_id" => ctx.italy.id,
        "stop_ids" => [ctx.rome.id, ctx.cairo.id]
      })

      assert errors(view, "stop_ids") == [@not_offered]
      assert trip(code) == nil

      push_submit(view, %{
        "code" => code,
        "country_id" => ctx.italy.id,
        "stop_ids" => [ctx.rome.id, ctx.genoa.id]
      })

      assert stop_ids(code) |> Enum.sort() == Enum.sort([ctx.rome.id, ctx.genoa.id])
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

    test "refuses a label the hook's filter leaves out", ctx do
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")
      code = unique("T")

      push_submit(view, %{"code" => code, "labels" => [ctx.open.name, ctx.restricted.name]})

      assert errors(view, "labels") == [@not_offered]
      assert trip(code) == nil
    end

    # The change looks a name up through the destination's primary read,
    # which finds an archived label the lookup action hides: it would be
    # related, not created.
    test "refuses a label its lookup action hides", ctx do
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")
      code = unique("T")

      push_submit(view, %{"code" => code, "labels" => [ctx.archived.name]})

      assert errors(view, "labels") == [@not_offered]
      assert trip(code) == nil
    end

    test "relates a label it offers when its name is posted in another case", ctx do
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")
      code = unique("T")

      push_submit(view, %{"code" => code, "labels" => [String.upcase(ctx.open.name)]})

      assert errors(view, "labels") == []
      assert [%{id: id}] = labels(code)
      assert id == ctx.open.id
    end

    test "still creates a new name, beside a label it offers", ctx do
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")
      code = unique("T")
      new = unique("New")

      push_submit(view, %{"code" => code, "labels" => [ctx.open.name, new]})

      assert label_names(code) |> Enum.sort() == Enum.sort([ctx.open.name, new])
    end
  end

  describe "a relationship's own filter" do
    test "refuses a pick it leaves out at the save", ctx do
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")
      code = unique("T")

      push_submit(view, %{"code" => code, "port_id" => ctx.rome.id})

      assert errors(view, "port_id") == [@not_offered]
      assert trip(code) == nil

      push_submit(view, %{"code" => code, "port_id" => ctx.genoa.id})
      assert trip(code).port_id == ctx.genoa.id
    end

    test "leaves alone what an update's record already holds", ctx do
      # Stored before the filter could say no: the save does not change it.
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

    test "refuses a value outside them at the save", ctx do
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")
      code = unique("T")

      push_submit(view, %{"code" => code, "status" => "approved"})

      assert errors(view, "status") == [@not_offered]
      assert trip(code) == nil
    end

    test "flags the value an update's record holds outside them", ctx do
      record = create(status: :approved)
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/#{record.id}/update")

      # Still drawn as what the field holds, but no longer offered.
      assert PickerDriver.picked(view, "form_status-picker") == ["Approved"]
      assert PickerDriver.search(view, "form_status-picker") == ["Draft", "Submitted"]

      view |> form(@form) |> render_submit()
      assert errors(view, "status") == [@not_offered]

      push_submit(view, %{"code" => record.code, "status" => "submitted"})
      assert trip(record.code).status == :submitted
    end

    test "narrows a sub-form's row by its parent's value", ctx do
      {:ok, view, _html} = live(ctx.conn, "/test/picked_places/create")
      code = unique("T")

      view
      |> element("#{@form} [phx-click=add-form][phx-value-path='form[legs]']")
      |> render_click()

      change(view, %{"code" => code, "kind" => "cruise"}, "kind")

      assert PickerDriver.search(view, "form_legs_0_mode-picker") == ["Ship"]

      push_submit(view, %{
        "code" => code,
        "kind" => "cruise",
        "legs" => %{"0" => %{"mode" => "bus"}}
      })

      assert errors(view, "legs_0_mode") == [@not_offered]
      assert trip(code) == nil

      push_submit(view, %{
        "code" => code,
        "kind" => "tour",
        "legs" => %{"0" => %{"mode" => "bus"}}
      })

      assert [%{mode: :bus}] = trip(code).legs
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

  defp labels(code),
    do: code |> trip() |> Ash.load!(:labels, authorize?: false) |> Map.fetch!(:labels)

  defp label_names(code), do: code |> labels() |> Enum.map(&to_string(&1.name))

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

  defp stop_ids(code),
    do:
      code
      |> trip()
      |> Ash.load!(:stops, authorize?: false)
      |> Map.fetch!(:stops)
      |> Enum.map(& &1.id)

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

  defp push_submit(view, params), do: render_submit(view, "save", %{"form" => params})

  defp errors(view, field) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#{@form} [id$='_#{field}-errors'] p")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
