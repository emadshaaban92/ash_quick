defmodule ExampleWeb.SensitiveScenarioTest do
  @moduledoc """
  A `sensitive?` field is redacted wherever AshQuick puts it: the list, the
  details page, the page title, the form, and a file. Nor can a list be
  filtered or sorted by one, which would give its value back.

  `Example.Test.Secrets` is labelled by its `sensitive?` PIN and carries a
  `sensitive?` date, so its label and a value of a type that would otherwise
  be formatted are both exercised. Only this test writes to its table.
  """
  use ExampleWeb.FeatureCase, async: true

  alias AshQuick.LiveView.QuickView.Options
  alias Example.Test.{S3Stub, Secrets}

  @modal "#ash-quick-action-modal"
  @refused "That filter couldn&#39;t be applied to this list"
  @export_timeout to_timeout(second: 5)

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  # Not digits alone: a page and a CSV hold random UUIDs, which can hold any
  # four of them.
  defp secret do
    Ash.create!(Secrets, %{code: unique("S"), pin: "pin-4321-zq", issued_on: ~D[2026-10-19]})
  end

  test "the list, the details page and its title show neither value", %{conn: conn} do
    secret = secret()

    {:ok, list, _html} = live(conn, ~p"/test/secrets?search=#{secret.code}")
    html = render(list)

    assert html =~ secret.code
    assert html =~ "********"
    refute html =~ "pin-4321-zq"
    refute html =~ "Oct 19, 2026"

    {:ok, details, _html} = live(conn, ~p"/test/secrets/#{secret.id}")
    html = render(details)

    # The PIN is the label, so it is the heading and the title too.
    assert html =~ "********"
    refute html =~ "pin-4321-zq"
    refute html =~ "Oct 19, 2026"
    # The title is sent as an update, so it is read after moving to the
    # record from the list, the way a click on its row does.
    render_patch(list, ~p"/test/secrets/#{secret.id}")

    assert page_title(list) =~ "Secrets - ********"
    refute page_title(list) =~ "pin-4321-zq"
  end

  test "the update form holds no stored value, and a blank one keeps it", %{conn: conn} do
    secret = secret()

    {:ok, view, html} = live(conn, ~p"/test/secrets/#{secret.id}/update")

    refute html =~ "pin-4321-zq"
    assert has_element?(view, ~s(#{@modal} input[type=password][name="form[pin]"]))
    assert has_element?(view, ~s(#{@modal} input[placeholder="Leave blank to keep it"]))

    renamed = unique("S")

    view
    |> form("#{@modal} form[phx-submit=save]", %{"form" => %{"code" => renamed, "pin" => ""}})
    |> render_submit()

    assert %{code: ^renamed, pin: "pin-4321-zq"} = Ash.get!(Secrets, secret.id)

    # A value typed in replaces it.
    {:ok, view, _html} = live(conn, ~p"/test/secrets/#{secret.id}/update")

    view
    |> form("#{@modal} form[phx-submit=save]", %{"form" => %{"pin" => "8765"}})
    |> render_submit()

    assert %{pin: "8765"} = Ash.get!(Secrets, secret.id)
  end

  test "an export redacts them", ctx do
    %{conn: conn, admin: admin} = ctx
    secret = secret()

    {:ok, view, _html} = live(conn, ~p"/test/secrets?search=#{secret.code}")

    view |> element("a", "CSV") |> render_click()
    render_async(view, @export_timeout)

    csv = exported_csv(admin)

    assert csv =~ secret.code
    assert csv =~ "********"
    refute csv =~ "pin-4321-zq"
    refute csv =~ "Oct 19, 2026"
  end

  describe "a filter" do
    test "is not offered on either field", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/test/secrets?show_custom_filter=true")

      assert texts(view, "select[name^='field_name-'] option") == ["Id", "Code"]
    end

    # Rows that start with "pin-4", then "pin-43", would read the PIN back a
    # character at a time, with only the list to read it off.
    test "on one, from a link, is dropped, saying so", %{conn: conn} do
      secret = secret()

      for prefix <- ["pin-43", "pin-9"] do
        filter =
          encode_filter([
            %{"field_name" => "pin", "operator" => "starts_with", "value" => prefix}
          ])

        {:ok, view, html} =
          live(conn, "/test/secrets?search=#{secret.code}&custom_filter=#{filter}")

        assert html =~ @refused
        assert secret.code in texts(view, "td")
      end
    end

    test "naming one is refused when the QuickView compiles" do
      message =
        Exception.message(
          assert_raise(ArgumentError, fn -> options(filterable: [:code, :pin, :issued_on]) end)
        )

      assert message =~ "* :pin is not a field the filter offers"
      assert message =~ "* :issued_on is not a field the filter offers"
      assert message =~ "or `sensitive?` field"
      refute message =~ "* :code"
    end
  end

  describe "a sort" do
    test "is offered on neither field, and a link's is dropped", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/test/secrets?sort=-pin")

      assert sort_links(view) == ["code"]
      refute has_element?(view, "th[aria-sort]")
    end

    test "naming one is refused when the QuickView compiles" do
      message =
        Exception.message(assert_raise(ArgumentError, fn -> options(sortable: [:code, :pin]) end))

      assert message =~ "* :pin is `sensitive?`; the order of the rows would give it away"
      refute message =~ "* :code"
    end
  end

  defp options(list_opts) do
    Options.new(__MODULE__.SomeQuickView, Secrets,
      resource: Secrets,
      list: [fields: [:code, :pin, :issued_on]] ++ list_opts
    )
  end

  defp encode_filter(rows) do
    %{"operator" => "and", "children" => rows}
    |> JSON.encode!()
    |> :base64.encode()
    |> URI.encode_www_form()
  end

  defp sort_links(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("thead a[data-sort]")
    |> Enum.flat_map(&LazyHTML.attribute(&1, "data-sort"))
  end

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  # Exports are keyed by the actor, and every test makes its own users, so
  # this finds exactly the file this test's click produced.
  defp exported_csv(actor) do
    prefix = "exports/#{actor.id}/"

    assert body =
             Enum.find_value(1..40, fn _attempt ->
               case Enum.find(S3Stub.keys(), &String.contains?(&1, prefix)) do
                 nil ->
                   Process.sleep(25)
                   nil

                 key ->
                   S3Stub.body(key)
               end
             end),
           "nothing was uploaded under #{prefix}"

    body
  end
end
