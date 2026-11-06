defmodule ExampleWeb.FilterableScenarioTest do
  @moduledoc """
  A list that names the fields its filter offers, with `list: [filterable:
  ...]`: the form offers those, in that order, and a link's filter row on any
  other field is dropped before the read; `filterable: []` leaves the filter
  out.

  Over `Example.Test.FilterFields`, in ETS: `/test/filter_fields_named`
  offers a stage, a code and a salary only an admin may see, and
  `/test/filter_fields_none` offers nothing. The table is shared with other
  async cases, so each test matches codes it made unique.
  """
  use ExampleWeb.FeatureCase, async: true

  alias AshQuick.LiveView.QuickView.Options
  alias Example.Test.FilterFields

  @refused "That filter couldn&#39;t be applied to this list"

  describe "the fields named" do
    test "are the ones the form offers, in their order", %{conn: conn, admin: admin} do
      {:ok, view, _html} =
        live(log_in(conn, admin), "/test/filter_fields_named?show_custom_filter=true")

      assert texts(view, "select[name^='field_name-'] option") == ["Stage", "Code", "Salary"]
    end

    test "are still narrowed by field policies", %{conn: conn, editor: editor} do
      {:ok, view, _html} =
        live(log_in(conn, editor), "/test/filter_fields_named?show_custom_filter=true")

      assert texts(view, "select[name^='field_name-'] option") == ["Stage", "Code"]
    end

    test "filter the list as any field does", %{conn: conn, admin: admin} do
      code = unique("FN")
      kept = filter_field(code: code, stage: :live)
      dropped = filter_field(code: "#{code}-draft", stage: :draft)

      filter =
        encode_filter([
          %{"field_name" => "code", "operator" => "starts_with", "value" => code},
          %{"field_name" => "stage", "operator" => "equals", "value" => "live"}
        ])

      {:ok, view, html} =
        live(log_in(conn, admin), "/test/filter_fields_named?custom_filter=#{filter}")

      refute html =~ @refused
      assert kept.code in texts(view, "td")
      refute dropped.code in texts(view, "td")
    end

    # A link written for a page offering every field, or by hand: the row on
    # a field this list does not offer is dropped, so its table is never read
    # by that field, and the visitor is told. The rest of the filter stands.
    test "leave out a link's row on any other field, saying so", %{conn: conn, admin: admin} do
      code = unique("FN")
      row = filter_field(code: code, active: false)

      filter =
        encode_filter([
          %{"field_name" => "active", "operator" => "equals", "value" => "true"},
          %{"field_name" => "code", "operator" => "equals", "value" => code}
        ])

      {:ok, view, html} =
        live(log_in(conn, admin), "/test/filter_fields_named?custom_filter=#{filter}")

      assert html =~ @refused
      assert row.code in texts(view, "td")
      assert chips(view) == ["Code = #{code}"]
    end

    test "keep that row where the field is offered", %{conn: conn, admin: admin} do
      code = unique("FN")
      filter_field(code: code, active: false)

      filter =
        encode_filter([
          %{"field_name" => "active", "operator" => "equals", "value" => "true"},
          %{"field_name" => "code", "operator" => "equals", "value" => code}
        ])

      {:ok, view, html} = live(log_in(conn, admin), "/test/filter_fields?custom_filter=#{filter}")

      refute html =~ @refused
      refute code in texts(view, "td")
    end

    test "are checked when the QuickView compiles" do
      message =
        Exception.message(
          assert_raise(ArgumentError, fn ->
            options(filterable: [:code, :tags, :parent_id, :missing, [parent: :code], :stage])
          end)
        )

      assert message =~ "lets its list be filtered by fields it cannot be filtered by"
      assert message =~ "* :tags is not a field the filter offers"
      assert message =~ "* :parent_id is not a field the filter offers"
      assert message =~ "* :missing is not a field the filter offers"
      assert message =~ "* [parent: :code] is not a field name"
      refute message =~ "* :code"
      refute message =~ "* :stage"
    end

    test "need not be list columns, and are held once each" do
      assert %Options{list_filterable: [:stage, :code]} =
               options(filterable: [:stage, :code, :stage])
    end

    test "are every field the form can take when the option is not given" do
      assert %Options{list_filterable: nil} = options([])
    end
  end

  describe "no fields named" do
    test "leave the filter button out", %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(log_in(conn, admin), "/test/filter_fields_none")

      refute has_element?(view, "a[title='Advanced filters']")
      assert has_element?(view, "th", "Code")
    end

    test "open no filter form from a link", %{conn: conn, admin: admin} do
      {:ok, view, _html} =
        live(log_in(conn, admin), "/test/filter_fields_none?show_custom_filter=true")

      refute has_element?(view, "#custom-filter-form")
    end

    test "drop a link's filter whole, saying so", %{conn: conn, admin: admin} do
      code = unique("FN")
      row = filter_field(code: code, active: false)

      filter =
        encode_filter([%{"field_name" => "active", "operator" => "equals", "value" => "true"}])

      {:ok, view, html} =
        live(log_in(conn, admin), "/test/filter_fields_none?custom_filter=#{filter}")

      assert html =~ @refused
      assert row.code in texts(view, "td")
      assert chips(view) == []
    end
  end

  defp options(list_opts) do
    Options.new(__MODULE__.SomeQuickView, FilterFields,
      resource: FilterFields,
      list: [fields: [:code]] ++ list_opts
    )
  end

  defp encode_filter(rows) do
    %{"operator" => "and", "children" => rows}
    |> JSON.encode!()
    |> :base64.encode()
    |> URI.encode_www_form()
  end

  defp filter_field(attrs) do
    Ash.create!(FilterFields, Map.new(attrs), authorize?: false)
  end

  # Each chip's words, spaces collapsed, without its ✕.
  defp chips(view) do
    view
    |> texts("[data-filter-chip] > span[id$='-text']")
    |> Enum.map(&String.replace(&1, ~r/\s+/, " "))
  end

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
