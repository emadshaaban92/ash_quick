defmodule ExampleWeb.RelatedFilterScenarioTest do
  @moduledoc """
  A list filtered by fields of a related resource, through a belongs_to its
  `filterable:` names, as `[owner: :name]`: the form offers each as "Owner ›
  Name", draws its value as the owner's field is drawn, and the read keeps
  only the rows whose owner matches, never one the reader may not read.

  Over `Example.Test.RelatedFilter.Item`, in ETS: `/test/related_filter`
  offers an item's code and its owner's name, level, pin and note, and
  `/test/related_filter_default` names no `filterable:`. `/test/brand_filter`
  reads a product's brand through AshPostgres. The tables are shared with
  other async cases, so each test matches codes it made unique.

  An owner's motto shows only to its `:index` read, which an item's steward
  reads it with, so the filter offers it through `steward` and not `owner`.

  `/test/vault_filter` reaches a vault an editor may read only through an
  item, and a locked record only an admin reads.
  """
  use ExampleWeb.FeatureCase, async: true

  import ExampleWeb.FilterPicker

  alias AshQuick.LiveView.CustomFilter
  alias AshQuick.LiveView.QuickView.Options
  alias Example.Test.RelatedFilter.Item
  alias Example.Test.RelatedFilter.Locked
  alias Example.Test.RelatedFilter.Owner
  alias Example.Test.RelatedFilter.Vault
  alias Example.Test.S3Stub

  @refused "That filter couldn&#39;t be applied to this list"
  @export_timeout to_timeout(second: 5)

  describe "the form" do
    test "offers the owner's fields named, each after the owner", %{conn: conn, admin: admin} do
      {:ok, view, _html} =
        live(log_in(conn, admin), "/test/related_filter?show_custom_filter=true")

      assert texts(view, "select[name^='field_name-'] option") ==
               [
                 "Code",
                 "Owner › Name",
                 "Owner › Level",
                 "Owner › Pin",
                 "Owner › Note",
                 "Steward › Motto"
               ]
    end

    test "leaves out an owner's field a field policy hides", %{conn: conn, editor: editor} do
      {:ok, view, _html} =
        live(log_in(conn, editor), "/test/related_filter?show_custom_filter=true")

      assert texts(view, "select[name^='field_name-'] option") ==
               ["Code", "Owner › Name", "Owner › Level", "Owner › Note", "Steward › Motto"]
    end

    # The motto's field policy shows it only to the owner's `:index` read:
    # `steward` names that read, `owner` names none, so the owner's primary
    # read is asked.
    test "asks a related field's policy of the read the relationship names",
         %{conn: conn, admin: admin} do
      {:ok, view, _html} =
        live(log_in(conn, admin), "/test/related_filter?show_custom_filter=true")

      options = texts(view, "select[name^='field_name-'] option")
      assert "Steward › Motto" in options
      refute "Owner › Motto" in options
    end

    test "offers no owner's field where `filterable:` names none", %{conn: conn, admin: admin} do
      {:ok, view, _html} =
        live(log_in(conn, admin), "/test/related_filter_default?show_custom_filter=true")

      assert texts(view, "select[name^='field_name-'] option") == ["Id", "Code"]
    end

    test "picks an owner's level from its set, as the owner labels it",
         %{conn: conn, admin: admin} do
      {:ok, view, _html} =
        live(log_in(conn, admin), "/test/related_filter?show_custom_filter=true")

      uuid = filter_uuid(view)
      filter_change(view, "field_name-#{uuid}", "owner.tier")

      assert texts(view, "select[name='value-#{uuid}'] option") == ["", "Bronze", "Gold member"]

      filter_change(view, "operator-#{uuid}", "in")
      focus_values(view, uuid)
      assert offered(view, uuid) == ["Bronze", "Gold member"]
    end

    # Is Empty is offered on a name no owner leaves empty: an item can have no
    # owner at all.
    test "asks whether an owner's field is empty, where every owner's is seen",
         %{conn: conn, admin: admin, editor: editor} do
      for {actor, note_operators} <- [{admin, ["Is Empty", "Is Not Empty"]}, {editor, []}] do
        {:ok, view, _html} =
          live(log_in(conn, actor), "/test/related_filter?show_custom_filter=true")

        uuid = filter_uuid(view)
        filter_change(view, "field_name-#{uuid}", "owner.name")
        assert emptiness(view, uuid) == ["Is Empty", "Is Not Empty"]

        filter_change(view, "field_name-#{uuid}", "owner.note")
        assert emptiness(view, uuid) == note_operators
      end
    end
  end

  describe "a row on an owner's field" do
    test "keeps the items whose owner matches, and says so on its chip",
         %{conn: conn, admin: admin} do
      name = unique("Ada")
      kept = item(owner: owner(name: name))
      dropped = item(owner: owner(name: "x#{name}"))
      unowned = item()

      view = apply_filter(log_in(conn, admin), "owner.name", "starts_with", name)

      assert applied(view) == [{"owner.name", "starts_with", name}]
      cells = texts(view, "td")
      assert kept.code in cells
      refute dropped.code in cells
      refute unowned.code in cells
      assert chips(view) == ["Owner › Name starts with #{name}"]
      assert has_element?(view, ~s([data-filter-chip="owner.name"]))
    end

    test "reads an owner's level by the owner's label", %{conn: conn, admin: admin} do
      gold = item(owner: owner(tier: :gold))
      bronze = item(owner: owner(tier: :bronze))

      filter =
        encode_filter([
          %{"field_name" => "owner.tier", "operator" => "equals", "value" => "gold"}
        ])

      {:ok, view, html} =
        live(log_in(conn, admin), "/test/related_filter?custom_filter=#{filter}")

      refute html =~ @refused
      assert gold.code in texts(view, "td")
      refute bronze.code in texts(view, "td")
      assert chips(view) == ["Owner › Level = Gold member"]
    end

    # Ash applies the owner's read policy to the path: an item is never kept
    # for an owner its reader may not read, so a filter cannot tell them one
    # exists.
    test "never matches an owner the reader may not read",
         %{conn: conn, admin: admin, editor: editor} do
      name = unique("Hidden")
      row = item(owner: owner(name: name, hidden: true))

      filter =
        encode_filter([%{"field_name" => "owner.name", "operator" => "equals", "value" => name}])

      {:ok, view, html} =
        live(log_in(conn, editor), "/test/related_filter?custom_filter=#{filter}")

      refute html =~ @refused
      refute row.code in texts(view, "td")

      {:ok, view, _html} =
        live(log_in(conn, admin), "/test/related_filter?custom_filter=#{filter}")

      assert row.code in texts(view, "td")
    end

    # Whoever reads it, and whatever the owner's read policy asks of them: a
    # policy that is a filter for the editor must not turn a missing owner
    # into a refused one. An owner the reader may not read is empty to them,
    # as its column shows it.
    test "is empty on an item with no owner, for any reader",
         %{conn: conn, admin: admin, editor: editor} do
      code = unique("RF")
      owned = item(code: "#{code}-owned", owner: owner())
      unowned = item(code: "#{code}-unowned")
      hidden = item(code: "#{code}-hidden", owner: owner(hidden: true))

      for {actor, empty, filled} <- [
            {admin, [unowned], [owned, hidden]},
            {editor, [unowned, hidden], [owned]}
          ] do
        for {operator, kept, dropped} <- [
              {"is_nil", empty, filled},
              {"is_not_nil", filled, empty}
            ] do
          filter =
            encode_filter([
              %{"field_name" => "code", "operator" => "starts_with", "value" => code},
              %{"field_name" => "owner.name", "operator" => operator, "value" => ""}
            ])

          {:ok, view, html} =
            live(log_in(conn, actor), "/test/related_filter?custom_filter=#{filter}")

          refute html =~ @refused
          cells = texts(view, "td")

          for row <- kept,
              do: assert(row.code in cells, "#{actor.role} #{operator} dropped #{row.code}")

          for row <- dropped,
              do: refute(row.code in cells, "#{actor.role} #{operator} kept #{row.code}")
        end
      end
    end

    # The owner's read policy is asked of the owner's row alone, so it does
    # not drop an item with no owner from the `or` beside it.
    test "leaves an item with no owner to the other rows of an or",
         %{conn: conn, editor: editor} do
      code = unique("RF")
      unowned = item(code: "#{code}-unowned")
      name = unique("Ada")
      owned = item(code: "x#{code}-owned", owner: owner(name: name))

      filter =
        encode_filter(
          [
            %{"field_name" => "code", "operator" => "starts_with", "value" => code},
            %{"field_name" => "owner.name", "operator" => "equals", "value" => name}
          ],
          "or"
        )

      {:ok, view, _html} =
        live(log_in(conn, editor), "/test/related_filter?custom_filter=#{filter}")

      assert unowned.code in texts(view, "td")
      assert owned.code in texts(view, "td")
    end
  end

  describe "a row on a field its policy hides on some owners" do
    # The note shows to an editor on a bronze owner only, so no operator may
    # match a gold owner's note for them, nor tell them what it holds.
    test "never matches the note of an owner it hides it on",
         %{conn: conn, admin: admin, editor: editor} do
      note = unique("Note")
      gold = item(owner: owner(tier: :gold, note: note))
      bronze = item(owner: owner(tier: :bronze, note: note))

      for {operator, value} <- [
            {"equals", note},
            {"starts_with", note},
            {"not_equals", "x#{note}"}
          ],
          {actor, kept} <- [{admin, [gold, bronze]}, {editor, [bronze]}] do
        filter =
          encode_filter([
            %{"field_name" => "code", "operator" => "in", "value" => [gold.code, bronze.code]},
            %{"field_name" => "owner.note", "operator" => operator, "value" => value}
          ])

        {:ok, view, html} =
          live(log_in(conn, actor), "/test/related_filter?custom_filter=#{filter}")

        refute html =~ @refused
        cells = texts(view, "td")

        for row <- [gold, bronze] do
          assert row.code in cells == row in kept,
                 "#{actor.role} #{operator} #{if row in kept, do: "dropped", else: "kept"} " <>
                   "the #{row.code} row"
        end
      end
    end
  end

  describe "a row through the read a relationship names" do
    test "keeps the items whose steward matches", %{conn: conn, admin: admin} do
      motto = unique("Motto")
      kept = item(steward: owner(motto: motto))
      dropped = item(steward: owner(motto: "x#{motto}"))

      filter =
        encode_filter([
          %{"field_name" => "steward.motto", "operator" => "equals", "value" => motto}
        ])

      {:ok, view, html} =
        live(log_in(conn, admin), "/test/related_filter?custom_filter=#{filter}")

      refute html =~ @refused
      assert kept.code in texts(view, "td")
      refute dropped.code in texts(view, "td")
      assert chips(view) == ["Steward › Motto = #{motto}"]
    end

    test "is dropped where that read is not the one asked, saying so",
         %{conn: conn, admin: admin} do
      motto = unique("Motto")
      row = item(owner: owner(motto: motto))
      other = item(owner: owner())

      filter =
        encode_filter([
          %{"field_name" => "owner.motto", "operator" => "equals", "value" => motto}
        ])

      {:ok, view, html} =
        live(log_in(conn, admin), "/test/related_filter?custom_filter=#{filter}")

      assert html =~ @refused
      assert row.code in texts(view, "td")
      assert other.code in texts(view, "td")
    end
  end

  # A vault's read and code are allowed through an item's `vault` only, so an
  # editor sees both in the vault's column and never on a read of the vault
  # itself. The filter asks as the column does, through the relationship.
  describe "a row on a destination read only through the relationship" do
    test "is offered as its column shows it, and a destination no route reaches is not",
         %{conn: conn, admin: admin, editor: editor} do
      for {actor, options} <- [
            {admin, ["Code", "Vault › Name", "Vault › Code", "Locked › Name"]},
            {editor, ["Code", "Vault › Name", "Vault › Code"]}
          ] do
        {:ok, view, _html} =
          live(log_in(conn, actor), "/test/vault_filter?show_custom_filter=true")

        assert texts(view, "select[name^='field_name-'] option") == options
      end
    end

    test "keeps the items whose vault matches, for a reader who reaches it only so",
         %{conn: conn, editor: editor} do
      code = "vault-#{unique("zq")}"
      gold = vault(code: code)
      kept = item(vault: gold)
      dropped = item(vault: vault(code: "x#{code}"))
      unvaulted = item()

      for {field, value} <- [{"vault.code", code}, {"vault.name", gold.name}] do
        filter =
          encode_filter([%{"field_name" => field, "operator" => "equals", "value" => value}])

        {:ok, view, html} =
          live(log_in(conn, editor), "/test/vault_filter?custom_filter=#{filter}")

        refute html =~ @refused
        cells = texts(view, "td")
        assert kept.code in cells, "#{field} dropped the matching item"
        refute dropped.code in cells
        refute unvaulted.code in cells
      end
    end

    test "asks whether a vault's code is empty, for a reader who reaches it only so",
         %{conn: conn, editor: editor} do
      prefix = unique("RF")
      vaulted = item(code: "#{prefix}-vaulted", vault: vault(code: "vault-#{unique("zq")}"))
      unvaulted = item(code: "#{prefix}-unvaulted")

      {:ok, view, _html} =
        live(log_in(conn, editor), "/test/vault_filter?show_custom_filter=true")

      uuid = filter_uuid(view)
      filter_change(view, "field_name-#{uuid}", "vault.code")
      assert emptiness(view, uuid) == ["Is Empty", "Is Not Empty"]

      filter =
        encode_filter([
          %{"field_name" => "code", "operator" => "starts_with", "value" => prefix},
          %{"field_name" => "vault.code", "operator" => "is_nil", "value" => ""}
        ])

      {:ok, view, html} =
        live(log_in(conn, editor), "/test/vault_filter?custom_filter=#{filter}")

      refute html =~ @refused
      assert unvaulted.code in texts(view, "td")
      refute vaulted.code in texts(view, "td")
    end

    test "is dropped on a destination the reader may not read by any route, saying so",
         %{conn: conn, admin: admin, editor: editor} do
      name = unique("Locked")
      row = item(locked: Ash.Seed.seed!(Locked, %{name: name}))
      other = item()

      filter =
        encode_filter([%{"field_name" => "locked.name", "operator" => "equals", "value" => name}])

      {:ok, view, html} =
        live(log_in(conn, editor), "/test/vault_filter?custom_filter=#{filter}")

      assert html =~ @refused
      assert row.code in texts(view, "td")
      assert other.code in texts(view, "td")

      {:ok, view, html} =
        live(log_in(conn, admin), "/test/vault_filter?custom_filter=#{filter}")

      refute html =~ @refused
      assert row.code in texts(view, "td")
      refute other.code in texts(view, "td")
    end
  end

  # A link written for another page or reader, or by hand.
  describe "a link's row through a relationship" do
    test "is dropped where `filterable:` names no such field, saying so",
         %{conn: conn, admin: admin} do
      row = item(owner: owner(name: unique("Ada")))

      filter =
        encode_filter([%{"field_name" => "owner.name", "operator" => "equals", "value" => "x"}])

      {:ok, view, html} =
        live(log_in(conn, admin), "/test/related_filter_default?custom_filter=#{filter}")

      assert html =~ @refused
      assert row.code in texts(view, "td")
      assert chips(view) == []
    end

    test "is dropped on a field a field policy hides, saying so", %{conn: conn, editor: editor} do
      pin = "pin-#{unique("zq")}"
      row = item(owner: owner(pin: pin))
      other = item(owner: owner())

      filter =
        encode_filter([%{"field_name" => "owner.pin", "operator" => "equals", "value" => pin}])

      {:ok, view, html} =
        live(log_in(conn, editor), "/test/related_filter?custom_filter=#{filter}")

      assert html =~ @refused
      assert row.code in texts(view, "td")
      assert other.code in texts(view, "td")
      refute render(view) =~ pin
    end

    test "is dropped when it goes further than one hop, or through a has-many",
         %{conn: conn, admin: admin} do
      for name <- ["parent.owner.name", "children.code", "keeper.name", "owner.hidden"] do
        filter = encode_filter([%{"field_name" => name, "operator" => "equals", "value" => "x"}])

        {:ok, view, html} =
          live(log_in(conn, admin), "/test/related_filter?custom_filter=#{filter}")

        assert html =~ @refused, "#{name} was not refused"
        assert chips(view) == []
      end
    end
  end

  describe "on Postgres" do
    test "keeps the products of the brands matched", %{conn: conn, admin: admin} do
      name = unique("Acme")
      kept = product(brand: brand(name: name, actor: admin), actor: admin)
      dropped = product(brand: brand(name: "Other #{name}", actor: admin), actor: admin)

      filter =
        encode_filter([
          %{"field_name" => "brand.name", "operator" => "starts_with", "value" => name}
        ])

      {:ok, view, html} = live(log_in(conn, admin), "/test/brand_filter?custom_filter=#{filter}")

      refute html =~ @refused
      assert kept.sku in texts(view, "td")
      refute dropped.sku in texts(view, "td")
      assert chips(view) == ["Brand › Name starts with #{name}"]
    end

    test "exports only the products of the brands matched", %{conn: conn, admin: admin} do
      name = unique("Acme")
      kept = product(brand: brand(name: name, actor: admin), actor: admin)
      dropped = product(brand: brand(name: "Other #{name}", actor: admin), actor: admin)

      filter =
        encode_filter([
          %{"field_name" => "sku", "operator" => "in", "value" => [kept.sku, dropped.sku]},
          %{"field_name" => "brand.name", "operator" => "starts_with", "value" => name}
        ])

      {:ok, view, _html} = live(log_in(conn, admin), "/test/brand_filter?custom_filter=#{filter}")

      view |> element("a", "CSV") |> render_click()
      render_async(view, @export_timeout)

      [_header | rows] = admin |> exported_csv() |> String.split("\r\n", trim: true)

      assert Enum.map(rows, &(&1 |> String.split(",") |> hd())) == [kept.sku]
    end

    test "finds the products with no store, and those with one", %{conn: conn, admin: admin} do
      code = unique("ST")
      store = store(name: "#{code} shop", actor: admin)
      shelved = product(store: store, actor: admin)
      own = product(actor: admin)

      for {operator, kept, dropped} <- [{"is_nil", own, shelved}, {"is_not_nil", shelved, own}] do
        filter =
          encode_filter([
            %{"field_name" => "sku", "operator" => "in", "value" => [own.sku, shelved.sku]},
            %{"field_name" => "store.name", "operator" => operator, "value" => ""}
          ])

        {:ok, view, html} =
          live(log_in(conn, admin), "/test/brand_filter?custom_filter=#{filter}")

        refute html =~ @refused
        assert kept.sku in texts(view, "td")
        refute dropped.sku in texts(view, "td")
      end
    end
  end

  describe "`filterable:`" do
    test "takes an owner's field as a keyword or as a path list" do
      assert %Options{list_filterable: [{:owner, :name}, :code, {:owner, :tier}]} =
               options(filterable: [[owner: :name], :code, owner: :tier, owner: :name])
    end

    test "refuses what no row can filter by, when the QuickView compiles" do
      message =
        Exception.message(
          assert_raise(ArgumentError, fn ->
            options(
              filterable: [
                :code,
                [owner: [parent: :name]],
                children: :code,
                keeper: :name,
                ledger: :name,
                owner: :missing,
                owner: :name
              ]
            )
          end)
        )

      assert message =~ "* [owner: [parent: :name]] goes more than one relationship deep"
      assert message =~ "* {:children, :code} is not a field the filter offers through :children"
      assert message =~ "* {:keeper, :name} is not a field the filter offers through :keeper"

      assert message =~
               "* {:ledger, :name} is not a field the filter offers through :ledger, which " <>
                 "must be a public belongs_to relationship with a read of its destination to ask"

      assert message =~ "* {:owner, :missing} is not a field the filter offers"
      refute message =~ "* {:owner, :name}"
      refute message =~ "* :code"
    end
  end

  defp options(list_opts) do
    Options.new(__MODULE__.SomeQuickView, Item,
      resource: Item,
      list: [fields: [:code]] ++ list_opts
    )
  end

  defp owner(attrs \\ []) do
    Ash.Seed.seed!(Owner, Map.merge(%{name: unique("Owner")}, Map.new(attrs)))
  end

  defp item(attrs \\ []) do
    {owner, attrs} = Keyword.pop(attrs, :owner)
    {steward, attrs} = Keyword.pop(attrs, :steward)
    {vault, attrs} = Keyword.pop(attrs, :vault)
    {locked, attrs} = Keyword.pop(attrs, :locked)

    ids = %{
      owner_id: owner && owner.id,
      steward_id: steward && steward.id,
      vault_id: vault && vault.id,
      locked_id: locked && locked.id
    }

    Ash.Seed.seed!(Item, %{code: unique("RF")} |> Map.merge(ids) |> Map.merge(Map.new(attrs)))
  end

  defp vault(attrs) do
    Ash.Seed.seed!(Vault, Map.merge(%{name: unique("Vault")}, Map.new(attrs)))
  end

  defp apply_filter(conn, field, operator, value) do
    {:ok, view, _html} = live(conn, "/test/related_filter?show_custom_filter=true")
    uuid = filter_uuid(view)

    filter_change(view, "field_name-#{uuid}", field)
    filter_change(view, "operator-#{uuid}", operator)
    filter_change(view, "value-#{uuid}", value)
    view |> element("#custom-filter-form") |> render_submit()

    view
  end

  # The rows the URL the form just applied carries, as written there.
  #
  # Apply is the filter form's: it sends the list a message, and the list
  # patches once it has read the filtered rows, after `render_submit/1` has
  # returned. `render/1` waits for the view to work through that message, and
  # so for the patch, rather than racing the read against `assert_patch/1`'s
  # timeout.
  defp applied(view) do
    render(view)
    %URI{query: query} = view |> assert_patch() |> URI.parse()
    %{"custom_filter" => encoded} = URI.decode_query(query)

    for leaf <- encoded |> CustomFilter.from_string() |> CustomFilter.applied_leaves(),
        do: {leaf.field_name, leaf.operator, leaf.value}
  end

  # The operators a row offers that ask whether its field is empty.
  defp emptiness(view, uuid) do
    view
    |> texts("select[name='operator-#{uuid}'] option")
    |> Enum.filter(&(&1 in ["Is Empty", "Is Not Empty"]))
  end

  defp filter_uuid(view) do
    [name] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("select[name^='field_name-']")
      |> LazyHTML.attribute("name")

    String.replace_prefix(name, "field_name-", "")
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
  defp chips(view) do
    view
    |> texts("[data-filter-chip] > span[id$='-text']")
    |> Enum.map(&String.replace(&1, ~r/\s+/, " "))
  end

  # Exports are keyed by the actor, and every test makes its own users, so
  # this finds exactly the file this test's click produced.
  defp exported_csv(actor) do
    key = "exports/#{actor.id}/"

    assert body =
             Enum.find_value(1..40, fn _attempt ->
               case Enum.find(S3Stub.keys(), &String.contains?(&1, key)) do
                 nil ->
                   Process.sleep(25)
                   nil

                 key ->
                   S3Stub.body(key)
               end
             end),
           "nothing was uploaded under #{key}"

    body
  end

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
