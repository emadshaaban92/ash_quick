defmodule ExampleWeb.StoredMapScenarioTest do
  @moduledoc """
  A map column whose keys are only known at runtime, as an audit row's
  `changes` is: one line in the list, a tree on the details page, one line
  in the export.

  Over `Example.Accounts.AuditLog`, whose list and details both show
  `:changes`. The rows are written straight to the table, so their shape is
  the test's: a write leaves whatever its action touched.
  """
  use ExampleWeb.FeatureCase, async: true

  import Phoenix.LiveViewTest,
    only: [live: 2, render: 1, element: 3, render_click: 1, render_async: 2]

  alias Example.Accounts.AuditLog
  alias Example.Test.S3Stub

  @export_timeout to_timeout(second: 5)

  setup do
    changes = %{
      "name" => %{"from" => "Tent", "to" => "Four-season tent"},
      "description" => %{"from" => nil, "to" => String.duplicate("Sleeps four. ", 30)},
      "password" => %{"from" => "**redacted**", "to" => "**redacted**"},
      "tags" => %{"from" => [], "to" => Enum.map(1..8, &"tag-#{&1}")}
    }

    entry =
      AuditLog
      |> Ash.Changeset.for_create(:create, %{
        resource_name: :product,
        resource_id: Ash.UUID.generate(),
        action_type: :update,
        action_name: :update,
        attributes: %{},
        arguments: %{},
        context: %{},
        changes: changes
      })
      |> Ash.create!(authorize?: false)

    %{entry: entry}
  end

  test "a list cell reads each key and value on one line", %{
    conn: conn,
    admin: admin,
    entry: entry
  } do
    {:ok, view, _html} = live(log_in(conn, admin), ~p"/audit_logs")

    [cell] = cells(view, entry)

    assert cell ==
             "description: {from: empty, to: Sleeps four. Sleeps fou…} · " <>
               "name: {from: Tent, to: Four-season tent} · " <>
               "password: {from: ********Redacted, to: ********Redacted} · " <>
               "tags: {from: [0 items], to: [8 items]}"
  end

  test "the details page is a tree, with the raw JSON beside it", ctx do
    %{conn: conn, admin: admin, entry: entry} = ctx

    {:ok, view, _html} = live(log_in(conn, admin), ~p"/audit_logs/#{entry.id}")
    doc = view |> render() |> LazyHTML.from_fragment()

    [tree] = doc |> LazyHTML.query(~s([data-stored-map="details"])) |> Enum.take(1)

    # `from`/`to` pairs start open; a list of eight starts closed.
    assert [name] = tree |> LazyHTML.query(~s(li[data-key="name"] > details)) |> Enum.to_list()
    assert LazyHTML.attribute(name, "open") == [""]
    assert LazyHTML.text(name) =~ "Four-season tent"

    assert [to] =
             tree
             |> LazyHTML.query(~s(li[data-key="tags"] li[data-key="to"] > details))
             |> Enum.to_list()

    assert LazyHTML.attribute(to, "open") == []
    assert LazyHTML.text(to) =~ "8 items"

    refute tree |> LazyHTML.query("ul") |> LazyHTML.text() =~ "**redacted**"
    assert LazyHTML.text(tree) =~ "Show all"
    assert LazyHTML.text(tree) =~ "Raw JSON"

    # Named for the resource and the field's place among the details, so the
    # Copy button finds its own Raw JSON. `:changes` is the fifth field.
    assert [raw] = doc |> LazyHTML.query("pre#audit_log-field-4-raw") |> Enum.to_list()
    assert raw |> LazyHTML.text() |> JSON.decode!() == entry.changes

    assert doc
           |> LazyHTML.query(
             ~s(button#audit_log-field-4-copy[data-copy-from="audit_log-field-4-raw"])
           )
           |> Enum.count() == 1
  end

  test "the export holds the whole map on one line", %{conn: conn, admin: admin, entry: entry} do
    {:ok, view, _html} = live(log_in(conn, admin), ~p"/audit_logs")

    view |> element("a", "CSV") |> render_click()
    render_async(view, @export_timeout)

    [row] =
      admin
      |> exported_csv()
      |> String.split("\r\n", trim: true)
      |> Enum.filter(&String.contains?(&1, entry.resource_id))

    assert row =~ ~s("{""description"":{""from"":null,)
  end

  describe "a list of maps" do
    alias Example.Test.StoredMapLists

    setup do
      # Seeded: no form writes a stored map, so no action takes one.
      record =
        Ash.Seed.seed!(StoredMapLists, %{
          code: "Order #{System.unique_integer([:positive])}",
          entries: [%{"sku" => "A-1", "qty" => 1}, %{"sku" => "B-2", "qty" => 2}]
        })

      %{record: record}
    end

    test "a details page draws each item, its Raw JSON the list", ctx do
      %{conn: conn, admin: admin, record: record} = ctx

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/test/stored_map_lists/#{record.id}")
      doc = view |> render() |> LazyHTML.from_fragment()

      [tree] = doc |> LazyHTML.query(~s([data-stored-map="details"])) |> Enum.to_list()

      assert [first, second] =
               tree |> LazyHTML.query(~s(ul > li[data-key] > details)) |> Enum.to_list()

      assert LazyHTML.text(first) =~ "A-1"
      assert LazyHTML.text(second) =~ "B-2"

      # `:entries` is the second field.
      assert [raw] = doc |> LazyHTML.query("pre#stored_map_lists-field-1-raw") |> Enum.to_list()
      assert raw |> LazyHTML.text() |> JSON.decode!() == record.entries

      assert doc |> LazyHTML.query("button#stored_map_lists-field-1-copy") |> Enum.count() == 1
    end

    test "the export holds the list as one JSON list", ctx do
      %{conn: conn, admin: admin, record: record} = ctx

      {:ok, view, _html} = live(log_in(conn, admin), ~p"/test/stored_map_lists")

      view |> element("a", "CSV") |> render_click()
      render_async(view, @export_timeout)

      [row] =
        admin
        |> exported_csv()
        |> String.split("\r\n", trim: true)
        |> Enum.filter(&String.contains?(&1, record.code))

      assert row ==
               ~s(#{record.code},"[{""qty"":1,""sku"":""A-1""},{""qty"":2,""sku"":""B-2""}]")
    end
  end

  # The cells of the column headed "Changes", in the entry's row.
  defp cells(view, entry) do
    doc = view |> render() |> LazyHTML.from_fragment()
    headers = doc |> LazyHTML.query("thead th") |> Enum.map(&String.trim(LazyHTML.text(&1)))
    index = Enum.find_index(headers, &(&1 == "Changes"))

    doc
    |> LazyHTML.query("tbody tr")
    |> Enum.filter(&(LazyHTML.text(&1) =~ entry.resource_id))
    |> Enum.map(fn row ->
      row
      |> LazyHTML.query("td")
      |> Enum.at(index)
      |> LazyHTML.text()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
    end)
  end

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
end
