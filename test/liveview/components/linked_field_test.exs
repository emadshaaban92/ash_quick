defmodule AshQuick.LiveView.Components.LinkedFieldTest do
  @moduledoc """
  A related record a details field names, rendered with a linker — the
  function from a record to its page that the details view builds once per
  render.

  The linker is handed in, so what is pinned here is the rendering alone: a
  label renders through its own field and the link goes around it, and only
  a label the reader can read is a link. Whether a reader gets a page at all
  is `AshQuick.Nav.Info.details_linker/3`'s, and the page built on both is the
  example app's to drive.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AshQuick.LiveView.Components.FieldValue
  alias AshQuick.LiveView.DetailsUtils
  alias AshQuick.LiveView.QuickField
  alias AshQuick.Test.Linked.{Assembly, Maker, Part, Vault}

  defp linker(record), do: "/linked/#{record.id}"

  defp render_field(record, path, linker \\ &linker/1) do
    render_component(&FieldValue.field_value/1, value: record, path: path, linker: linker)
  end

  defp maker(attrs \\ []),
    do: struct(Maker, Keyword.merge([id: Ash.UUID.generate(), name: "Acme", code: "AC-1"], attrs))

  defp part(attrs), do: struct(Part, Keyword.merge([id: Ash.UUID.generate()], attrs))

  defp link_attributes(html, record) do
    [{"a", attributes, _children}] = html |> link(record) |> LazyHTML.to_tree()
    attributes
  end

  defp link(html, maker),
    do: LazyHTML.query(LazyHTML.from_fragment(html), "a[href='/linked/#{maker.id}']")

  describe "a path reaching the related record's label" do
    test "is a link to it, carrying its hint" do
      maker = maker()
      html = render_field(part(maker: maker), maker: :name)

      assert [{"a", attrs, _}] = html |> link(maker) |> LazyHTML.to_tree()
      assert {"title", "AC-1"} in attrs
      assert {"aria-label", "Acme (AC-1)"} in attrs
      assert html |> link(maker) |> LazyHTML.text() == "Acme"
    end

    test "in its list form too" do
      maker = maker()

      assert render_field(part(maker: maker), maker: [:name]) |> link(maker) |> Enum.count() == 1
    end

    test "at any depth" do
      maker = maker()

      html =
        render_field(part(assembly: %Assembly{id: Ash.UUID.generate(), maker: maker}),
          assembly: [maker: :name]
        )

      assert html |> link(maker) |> Enum.count() == 1
    end

    # Hidden by a field policy: the page shows the mark it always did, and
    # neither the id nor a link that would say nothing.
    test "is the hidden mark, unlinked, when the reader may not read the label" do
      maker = maker(name: %Ash.ForbiddenField{field: :name, type: :attribute})
      html = render_field(part(maker: maker), maker: :name)

      assert html =~ "Hidden"
      refute html =~ maker.id
      assert html |> link(maker) |> Enum.count() == 0
    end

    test "is blank, unlinked, when the label holds nothing" do
      maker = maker(name: nil)
      html = render_field(part(maker: maker), maker: :name)

      refute html =~ maker.id
      assert html |> link(maker) |> Enum.count() == 0
    end

    # The label's own field still decides how it reads — here, masked — and
    # the accessible name, which a screen reader reads aloud, is masked too.
    test "keeps the label's own formatting inside the link, and out of its name" do
      vault = %Vault{id: Ash.UUID.generate(), pin: "4321", code: "V-1"}
      html = render_field(part(vault: vault), vault: :pin)

      assert html |> link(vault) |> LazyHTML.text() == "********"
      assert {"aria-label", "******** (V-1)"} in link_attributes(html, vault)
      refute html =~ "4321"
    end

    test "renders the label alone, as before, with no linker" do
      maker = maker()
      html = render_field(part(maker: maker), [maker: :name], nil)

      assert html =~ "Acme"
      refute html =~ "<a"
    end
  end

  describe "a field stopping at the relationship" do
    test "is a link to the record" do
      maker = maker()

      assert render_field(part(maker: maker), :maker) |> link(maker) |> Enum.count() == 1
    end

    # Its label is the visible text as well as the accessible name here.
    test "masks a sensitive label, in the text and in the name" do
      vault = %Vault{id: Ash.UUID.generate(), pin: "4321", code: "V-1"}
      html = render_field(part(vault: vault), :vault)

      assert html |> link(vault) |> LazyHTML.text() == "********"
      assert {"aria-label", "******** (V-1)"} in link_attributes(html, vault)
      refute html =~ "4321"
    end

    test "is not a link when its label cannot be read" do
      maker = maker(name: %Ash.ForbiddenField{field: :name, type: :attribute})

      assert render_field(part(maker: maker), :maker) |> link(maker) |> Enum.count() == 0
    end
  end

  # The load and the render ask `QuickField.names_record?/2` the same
  # question, so every path the page links has its hint loaded. Asked a path
  # at a time, since two paths naming one maker load one hint.
  test "the details query loads the hint of every record a field names" do
    hint_load = &DetailsUtils.related_hint_load(Part, [QuickField.normalize(&1)])

    assert hint_load.(:maker) == [maker: [:code]]
    assert hint_load.(maker: :name) == [maker: [:code]]
    assert hint_load.(maker: [:name]) == [maker: [:code]]
    assert hint_load.(assembly: [maker: :name]) == [assembly: [maker: [:code]]]

    assert hint_load.(vault: :pin) == [vault: [:code]]

    # An assembly declares no hint, and a plain attribute names no record.
    assert hint_load.(assembly: :name) == []
    assert hint_load.(:name) == []
  end
end
