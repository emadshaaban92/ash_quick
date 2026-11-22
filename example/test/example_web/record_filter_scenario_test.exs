defmodule ExampleWeb.RecordFilterScenarioTest do
  @moduledoc """
  A list filtered by related records themselves, through a relationship its
  `filterable:` names alone, as `:owner` or `:tags`, or with a belongs_to of
  the destination, as `[tags: :tag_group]`: the form picks the records from
  a search, a link carries their ids, the chip names them, and the read
  keeps the rows whose relationship holds any of them, never by a record the
  reader may not read.

  Over `Example.Test.RelatedFilter.Item`, in ETS, at `/test/record_filter`:
  its owner, a belongs_to, its tags, a many-to-many, its tags' groups, its
  children, a has-many, its vault, which an editor reads only through the
  item, and its locked record, which only an admin reads.
  `/test/brand_record_filter` picks a product's brand and store through
  AshPostgres. The tables are shared with other async cases, so each test
  matches names it made unique.
  """
  use ExampleWeb.FeatureCase, async: true

  import ExampleWeb.FilterPicker
  import ExUnit.CaptureLog

  alias AshQuick.LiveView.CustomFilter
  alias AshQuick.LiveView.FilterField
  alias AshQuick.LiveView.FilterRecords
  alias AshQuick.LiveView.QuickView.Options
  alias Example.Test.RelatedFilter.Item
  alias Example.Test.RelatedFilter.ItemTag
  alias Example.Test.RelatedFilter.Locked
  alias Example.Test.RelatedFilter.Owner
  alias Example.Test.RelatedFilter.Tag
  alias Example.Test.RelatedFilter.TagGroup

  @refused "That filter couldn&#39;t be applied to this list"

  describe "the form" do
    # A vault an editor reads only through an item: a row on it would search
    # vaults directly, which finds none, so it is not offered either.
    test "offers a row picking each relationship's records, and none of one the reader can't read",
         %{conn: conn, admin: admin, editor: editor} do
      for {actor, options} <- [
            {admin, ["Code", "Owner", "Tags", "Tags › Tag Group", "Children", "Vault", "Locked"]},
            {editor, ["Code", "Owner", "Tags", "Tags › Tag Group", "Children"]}
          ] do
        {:ok, view, _html} =
          live(log_in(conn, actor), "/test/record_filter?show_custom_filter=true")

        assert texts(view, "select[name^='field_name-'] option") == options
      end
    end

    test "asks whether a relationship holds any record, where it can hold none",
         %{conn: conn, admin: admin} do
      {:ok, view, _html} =
        live(log_in(conn, admin), "/test/record_filter?show_custom_filter=true")

      uuid = filter_uuid(view)

      for field <- ["owner", "tags", "tags.tag_group", "children"] do
        filter_change(view, "field_name-#{uuid}", field)

        assert texts(view, "select[name='operator-#{uuid}'] option") ==
                 ["Any Of", "Is Empty", "Is Not Empty"]
      end

      {:ok, view, _html} =
        live(log_in(conn, admin), "/test/brand_record_filter?show_custom_filter=true")

      uuid = filter_uuid(view)
      filter_change(view, "field_name-#{uuid}", "brand")
      assert texts(view, "select[name='operator-#{uuid}'] option") == ["Any Of"]

      filter_change(view, "field_name-#{uuid}", "store")

      assert texts(view, "select[name='operator-#{uuid}'] option") ==
               ["Any Of", "Is Empty", "Is Not Empty"]
    end

    test "searches the records, picks one, and keeps the rows holding it",
         %{conn: conn, admin: admin} do
      prefix = unique("Pick")
      ada = owner(name: "#{prefix} Ada")
      _bea = owner(name: "#{prefix} Bea")
      kept = item(owner: ada)
      dropped = item(owner: owner())

      {:ok, view, _html} =
        live(log_in(conn, admin), "/test/record_filter?show_custom_filter=true")

      uuid = filter_uuid(view)
      filter_change(view, "field_name-#{uuid}", "owner")

      assert focus_values(view, uuid) != []
      assert search_values(view, uuid, prefix) == ["#{prefix} Ada", "#{prefix} Bea"]
      assert search_values(view, uuid, "#{prefix} A") == ["#{prefix} Ada"]

      # Among thousands of owners, only a search reaches hers.
      pick_values(view, uuid, ["#{prefix} Ada"], searched: true)
      assert picked(view, uuid) == ["#{prefix} Ada"]

      view |> element("#custom-filter-form") |> render_submit()

      assert applied(view) == [{"owner", "in", [ada.id]}]
      cells = texts(view, "td")
      assert kept.code in cells
      refute dropped.code in cells
      assert chips(view) == ["Owner is any of #{prefix} Ada"]
    end

    # LiveSelect tells a picked option from the others by its label, not its
    # value, so two held records sharing one would take a click on either for
    # the first, and post its id again rather than unpicking it.
    # A chip names the records in their own direction: a name of digits and
    # signs left to right on an Arabic page too.
    test "names the records in the chip in their own direction", %{conn: conn, admin: admin} do
      for {name, dir} <- [
            {"+20 #{System.unique_integer([:positive])}", "ltr"},
            {unique("Ada"), "auto"}
          ] do
        owner = owner(name: name)
        item(owner: owner)
        view = open(conn, admin, [row("owner", "in", [owner.id])])

        assert has_element?(view, ~s([data-filter-chip] span[dir="#{dir}"]), name)
      end
    end

    test "unpicks either of two records a link holds that share a name",
         %{conn: conn, admin: admin} do
      name = unique("Twin")
      ada = owner(name: name)
      bea = owner(name: name)
      ada_item = item(owner: ada)
      bea_item = item(owner: bea)

      {:ok, view, _html} =
        live(
          log_in(conn, admin),
          "/test/record_filter?show_custom_filter=true&custom_filter=" <>
            encode_filter([row("owner", "in", [ada.id, bea.id])])
        )

      [uuid] = row_uuids(view)
      assert picked(view, uuid) == [name, name]
      assert search_values(view, uuid, name) == [name, name]

      # Clicking the first in the dropdown unpicks that one, and only it.
      pick_values(view, uuid, [name], searched: true)
      assert picked(view, uuid) == [name]

      view |> element("#custom-filter-form") |> render_submit()

      assert [{"owner", "in", [kept_id]}] = applied(view)
      assert kept_id in [ada.id, bea.id]
      {kept, dropped} = if kept_id == ada.id, do: {ada_item, bea_item}, else: {bea_item, ada_item}
      cells = texts(view, "td")
      assert kept.code in cells
      refute dropped.code in cells
    end
  end

  describe "a link's record row" do
    test "keeps the items holding any tag picked, and names the tags on its chip",
         %{conn: conn, admin: admin} do
      red = tag(name: unique("Red"), code: "R1")
      blue = tag(name: unique("Blue"), code: "B1")
      green = tag()
      both = item(tags: [red, blue])
      red_only = item(tags: [red])
      green_only = item(tags: [green])
      untagged = item()

      view = open(conn, admin, [row("tags", "in", [red.id, blue.id])])

      cells = texts(view, "td")
      assert both.code in cells
      assert red_only.code in cells
      refute green_only.code in cells
      refute untagged.code in cells
      assert chips(view) == ["Tags is any of #{red.name} (R1), #{blue.name} (B1)"]
      refute render(view) =~ red.id

      # The form opened from the link holds the same tags, named.
      {:ok, view, _html} =
        live(
          log_in(conn, admin),
          "/test/record_filter?show_custom_filter=true&custom_filter=" <>
            encode_filter([row("tags", "in", [red.id, blue.id])])
        )

      [uuid] = row_uuids(view)
      assert squashed(picked(view, uuid)) == ["#{red.name} R1", "#{blue.name} B1"]
    end

    test "keeps the items with a tag in any group picked, two hops away",
         %{conn: conn, admin: admin} do
      group = tag_group(name: unique("Warm"))
      other = tag_group()
      kept = item(tags: [tag(), tag(tag_group: group)])
      dropped = item(tags: [tag(tag_group: other)])
      ungrouped = item(tags: [tag()])

      view = open(conn, admin, [row("tags.tag_group", "in", [group.id])])

      cells = texts(view, "td")
      assert kept.code in cells
      refute dropped.code in cells
      refute ungrouped.code in cells
      assert chips(view) == ["Tags › Tag Group is any of #{group.name}"]
    end

    test "keeps the items whose children hold any picked, through a has-many",
         %{conn: conn, admin: admin} do
      parent = item()
      child = item(parent: parent)
      childless = item()

      view = open(conn, admin, [row("children", "in", [child.id])])

      cells = texts(view, "td")
      assert parent.code in cells
      refute childless.code in cells
      refute child.code in cells
      assert chips(view) == ["Children is any of #{child.code}"]
    end

    test "is empty on an item holding no related record, and not empty on one holding any",
         %{conn: conn, admin: admin} do
      code = unique("RE")
      group = tag_group()
      grouped = item(code: "#{code}-grouped", owner: owner(), tags: [tag(tag_group: group)])
      tagged = item(code: "#{code}-tagged", tags: [tag()])
      bare = item(code: "#{code}-bare")

      for {field, operator, kept, dropped} <- [
            {"tags", "is_nil", [bare], [grouped, tagged]},
            {"tags", "is_not_nil", [grouped, tagged], [bare]},
            {"tags.tag_group", "is_nil", [tagged, bare], [grouped]},
            {"tags.tag_group", "is_not_nil", [grouped], [tagged, bare]},
            {"owner", "is_nil", [tagged, bare], [grouped]},
            {"owner", "is_not_nil", [grouped], [tagged, bare]}
          ] do
        view =
          open(conn, admin, [
            row("code", "starts_with", code),
            row(field, operator, "")
          ])

        cells = texts(view, "td")
        for row <- kept, do: assert(row.code in cells, "#{field} #{operator} dropped #{row.code}")
        for row <- dropped, do: refute(row.code in cells, "#{field} #{operator} kept #{row.code}")
      end
    end

    # The tag's read policy hides it from an editor: the chip and the picker
    # name it with a placeholder, and no item is kept for it.
    # Their labels are told apart by id, as any two sharing one are, but
    # their tags read as the placeholder alone.
    test "draws two records the reader may not read as plain placeholders",
         %{conn: conn, editor: editor} do
      one = tag(name: unique("Secret"), hidden: true)
      other = tag(name: unique("Secret"), hidden: true)

      {:ok, view, _html} =
        live(
          log_in(conn, editor),
          "/test/record_filter?show_custom_filter=true&custom_filter=" <>
            encode_filter([row("tags", "in", [one.id, other.id])])
        )

      [uuid] = row_uuids(view)
      assert picked(view, uuid) == ["Unavailable record", "Unavailable record"]
      refute render(view) =~ one.name
    end

    test "never names nor matches a record the reader may not read",
         %{conn: conn, admin: admin, editor: editor} do
      secret = tag(name: unique("Secret"), code: "S1", hidden: true)
      open_tag = tag(name: unique("Open"), code: "O1")
      hidden_only = item(tags: [secret])
      open_only = item(tags: [open_tag])
      filter = [row("tags", "in", [secret.id, open_tag.id])]

      view = open(conn, editor, filter)

      cells = texts(view, "td")
      refute hidden_only.code in cells
      assert open_only.code in cells
      assert chips(view) == ["Tags is any of Unavailable record, #{open_tag.name} (O1)"]
      refute render(view) =~ secret.name

      {:ok, view, _html} =
        live(
          log_in(conn, editor),
          "/test/record_filter?show_custom_filter=true&custom_filter=" <> encode_filter(filter)
        )

      [uuid] = row_uuids(view)
      assert squashed(picked(view, uuid)) == ["Unavailable record", "#{open_tag.name} O1"]
      refute render(view) =~ secret.name
      refute secret.name in search_values(view, uuid, secret.name)

      view = open(conn, admin, filter)
      assert hidden_only.code in texts(view, "td")
      assert chips(view) == ["Tags is any of #{secret.name} (S1), #{open_tag.name} (O1)"]
    end

    test "is dropped on a destination the reader may not read, saying so",
         %{conn: conn, admin: admin, editor: editor} do
      locked = Ash.Seed.seed!(Locked, %{name: unique("Locked")})
      row = item(locked: locked)
      other = item()
      filter = encode_filter([row("locked", "in", [locked.id])])

      {:ok, view, html} =
        live(log_in(conn, editor), "/test/record_filter?custom_filter=#{filter}")

      assert html =~ @refused
      assert row.code in texts(view, "td")
      assert other.code in texts(view, "td")
      refute render(view) =~ locked.name

      {:ok, view, html} = live(log_in(conn, admin), "/test/record_filter?custom_filter=#{filter}")

      refute html =~ @refused
      assert row.code in texts(view, "td")
      refute other.code in texts(view, "td")
      assert chips(view) == ["Locked is any of #{locked.name}"]
    end

    test "is dropped when it compares by an operator a record row does not take, saying so",
         %{conn: conn, admin: admin} do
      owner = owner()
      row = item(owner: owner)

      for {operator, value} <- [{"equals", owner.id}, {"contains", "x"}] do
        filter = encode_filter([row("owner", operator, value)])

        {:ok, view, html} =
          live(log_in(conn, admin), "/test/record_filter?custom_filter=#{filter}")

        assert html =~ @refused, "#{operator} was not refused"
        assert row.code in texts(view, "td")
        assert chips(view) == []
      end
    end
  end

  describe "on Postgres" do
    test "keeps the products of the brands picked, by the records rather than their names",
         %{conn: conn, admin: admin} do
      name = unique("Acme")
      acme = brand(name: name, actor: admin)
      twin = brand(name: name, actor: admin)
      kept = product(brand: acme, actor: admin)
      dropped = product(brand: twin, actor: admin)

      {:ok, view, _html} =
        live(log_in(conn, admin), "/test/brand_record_filter?show_custom_filter=true")

      uuid = filter_uuid(view)
      filter_change(view, "field_name-#{uuid}", "brand")

      # Two brands share the name, so each is told apart by its code.
      assert view |> search_values(uuid, name) |> squashed() |> Enum.sort() ==
               Enum.sort(["#{name} #{acme.code}", "#{name} #{twin.code}"])

      pick_values(view, uuid, ["#{name}\n    #{acme.code}"])
      view |> element("#custom-filter-form") |> render_submit()

      assert applied(view) == [{"brand", "in", [acme.id]}]
      assert kept.sku in texts(view, "td")
      refute dropped.sku in texts(view, "td")
      assert chips(view) == ["Brand is any of #{name} (#{acme.code})"]

      # Renamed, the brand is still the one the link holds.
      renamed = unique("Zenith")
      Ash.update!(acme, %{name: renamed}, actor: admin)

      {:ok, view, html} =
        live(
          log_in(conn, admin),
          "/test/brand_record_filter?custom_filter=" <>
            encode_filter([row("brand", "in", [acme.id])])
        )

      refute html =~ @refused
      assert kept.sku in texts(view, "td")
      refute dropped.sku in texts(view, "td")
      assert chips(view) == ["Brand is any of #{renamed} (#{acme.code})"]
    end

    test "finds the products with no store, and those with one", %{conn: conn, admin: admin} do
      store = store(actor: admin)
      shelved = product(store: store, actor: admin)
      own = product(actor: admin)

      for {operator, value, kept, dropped} <- [
            {"is_nil", "", own, shelved},
            {"is_not_nil", "", shelved, own},
            {"in", [store.id], shelved, own}
          ] do
        filter =
          encode_filter([
            row("sku", "in", [own.sku, shelved.sku]),
            row("store", operator, value)
          ])

        {:ok, view, html} =
          live(log_in(conn, admin), "/test/brand_record_filter?custom_filter=#{filter}")

        refute html =~ @refused
        assert kept.sku in texts(view, "td")
        refute dropped.sku in texts(view, "td")
      end
    end

    test "refuses an id that is no id of the destination, saying so",
         %{conn: conn, admin: admin} do
      product = product(actor: admin)
      filter = encode_filter([row("brand", "in", ["not-a-uuid"])])

      {:ok, view, html} =
        live(log_in(conn, admin), "/test/brand_record_filter?custom_filter=#{filter}")

      assert html =~ @refused
      assert product.sku in texts(view, "td")
    end
  end

  describe "the picker's read" do
    # `Example.Test.NamedRows.Counted` is labelled by a count of records held
    # per tenant, which a reader with no tenant cannot load.
    test "names a record by its id when its label needs a tenant the reader has not got",
         %{admin: admin} do
      counted = Ash.Seed.seed!(Example.Test.NamedRows.Counted, %{code: unique("C")})
      scope = Example.Scope.new(actor: admin)

      assert %{label: label} =
               counted_field()
               |> FilterRecords.search(nil, scope)
               |> Enum.find(&(&1.value == counted.id))

      assert label == counted.id

      assert FilterRecords.held(counted_field(), [counted.id], scope) == %{
               counted.id => %{label: counted.id, value: counted.id, name: counted.id, hint: nil}
             }
    end

    test "offers nothing from a read the destination refuses, and logs why", %{admin: admin} do
      scope = Example.Scope.new(actor: admin)

      log =
        capture_log(fn ->
          assert FilterRecords.search(counted_field(), %{"not" => "text"}, scope) == []
        end)

      assert log =~ "could not read Example.Test.NamedRows.Counted for a record filter"
    end
  end

  describe "`filterable:`" do
    test "takes a relationship alone, or with a belongs_to of its destination" do
      assert %Options{list_filterable: [:owner, :tags, {:tags, :tag_group}, :children]} =
               options(filterable: [:owner, :tags, [tags: :tag_group], :children])
    end

    test "refuses a relationship whose records no row can pick, when the QuickView compiles" do
      message =
        Exception.message(
          assert_raise(ArgumentError, fn ->
            options(
              filterable: [:ledger, :keeper, tags: :missing, owner: :tag_group, tags: :code]
            )
          end)
        )

      assert message =~ "* :ledger is not a field the filter offers, nor a relationship"
      assert message =~ "* :keeper is not a field the filter offers, nor a relationship"
      assert message =~ "* {:tags, :missing} is not a field the filter offers through :tags"
      assert message =~ "* {:owner, :tag_group} is not a field the filter offers through :owner"
      assert message =~ "* {:tags, :code} is not a field the filter offers through :tags"
    end
  end

  defp options(list_opts) do
    Options.new(__MODULE__.SomeQuickView, Item,
      resource: Item,
      list: [fields: [:code]] ++ list_opts
    )
  end

  defp counted_field do
    resource = Example.Test.NamedRows.Counted

    %FilterField{
      name: "counted",
      spec: :counted,
      field: Ash.Resource.Info.attribute(resource, :id),
      resource: resource,
      record?: true
    }
  end

  defp owner(attrs \\ []) do
    Ash.Seed.seed!(Owner, Map.merge(%{name: unique("Owner")}, Map.new(attrs)))
  end

  defp tag_group(attrs \\ []) do
    Ash.Seed.seed!(TagGroup, Map.merge(%{name: unique("Group")}, Map.new(attrs)))
  end

  defp tag(attrs \\ []) do
    {group, attrs} = Keyword.pop(attrs, :tag_group)

    Ash.Seed.seed!(
      Tag,
      %{name: unique("Tag"), tag_group_id: group && group.id} |> Map.merge(Map.new(attrs))
    )
  end

  defp item(attrs \\ []) do
    {owner, attrs} = Keyword.pop(attrs, :owner)
    {locked, attrs} = Keyword.pop(attrs, :locked)
    {parent, attrs} = Keyword.pop(attrs, :parent)
    {tags, attrs} = Keyword.pop(attrs, :tags, [])

    ids = %{
      owner_id: owner && owner.id,
      locked_id: locked && locked.id,
      parent_id: parent && parent.id
    }

    item =
      Ash.Seed.seed!(Item, %{code: unique("RF")} |> Map.merge(ids) |> Map.merge(Map.new(attrs)))

    for tag <- tags, do: Ash.Seed.seed!(ItemTag, %{item_id: item.id, tag_id: tag.id})
    item
  end

  defp row(field, operator, value),
    do: %{"field_name" => field, "operator" => operator, "value" => value}

  defp open(conn, actor, rows) do
    {:ok, view, html} =
      live(log_in(conn, actor), "/test/record_filter?custom_filter=#{encode_filter(rows)}")

    refute html =~ @refused
    view
  end

  # The rows the URL the form just applied carries, as written there. See
  # `ExampleWeb.RelatedFilterScenarioTest`'s.
  defp applied(view) do
    render(view)
    %URI{query: query} = view |> assert_patch() |> URI.parse()
    %{"custom_filter" => encoded} = URI.decode_query(query)

    for leaf <- encoded |> CustomFilter.from_string() |> CustomFilter.applied_leaves(),
        do: {leaf.field_name, leaf.operator, leaf.value}
  end

  defp filter_uuid(view) do
    [uuid] = row_uuids(view)
    uuid
  end

  defp row_uuids(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("select[name^='field_name-']")
    |> LazyHTML.attribute("name")
    |> Enum.map(&String.replace_prefix(&1, "field_name-", ""))
  end

  defp filter_change(view, name, value) do
    view
    |> element("#custom-filter-form")
    |> render_change(%{"_target" => [name], name => value})
  end

  defp encode_filter(rows, operator \\ "and") do
    %{"operator" => operator, "children" => rows}
    |> JSON.encode!()
    |> :base64.encode()
    |> URI.encode_www_form()
  end

  # Each chip's words, spaces collapsed, without its ✕.
  defp chips(view), do: view |> texts("[data-filter-chip] > span[id$='-text']") |> squashed()

  # A record's name and hint are drawn on lines of their own.
  defp squashed(texts), do: Enum.map(texts, &String.replace(&1, ~r/\s+/, " "))

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
