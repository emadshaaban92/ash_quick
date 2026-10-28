defmodule ExampleWeb.SensitiveScenarioTest do
  @moduledoc """
  A `sensitive?` field is redacted wherever AshQuick puts it: the list, the
  details page, the page title, the form, and a file.

  `Example.Test.Secrets` is labelled by its `sensitive?` PIN and carries a
  `sensitive?` date, so its label and a value of a type that would otherwise
  be formatted are both exercised. Only this test writes to its table.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.{S3Stub, Secrets}

  @modal "#ash-quick-action-modal"
  @export_timeout to_timeout(second: 5)

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  defp secret do
    Ash.create!(Secrets, %{code: unique("S"), pin: "4321", issued_on: ~D[2026-10-19]})
  end

  test "the list, the details page and its title show neither value", %{conn: conn} do
    secret = secret()

    {:ok, list, _html} = live(conn, ~p"/test/secrets?search=#{secret.code}")
    html = render(list)

    assert html =~ secret.code
    assert html =~ "********"
    refute html =~ "4321"
    refute html =~ "Oct 19, 2026"

    {:ok, details, _html} = live(conn, ~p"/test/secrets/#{secret.id}")
    html = render(details)

    # The PIN is the label, so it is the heading and the title too.
    assert html =~ "********"
    refute html =~ "4321"
    refute html =~ "Oct 19, 2026"
    # The title is sent as an update, so it is read after moving to the
    # record from the list, the way a click on its row does.
    render_patch(list, ~p"/test/secrets/#{secret.id}")

    assert page_title(list) =~ "Secrets - ********"
    refute page_title(list) =~ "4321"
  end

  test "the update form holds no stored value, and a blank one keeps it", %{conn: conn} do
    secret = secret()

    {:ok, view, html} = live(conn, ~p"/test/secrets/#{secret.id}/update")

    refute html =~ "4321"
    assert has_element?(view, ~s(#{@modal} input[type=password][name="form[pin]"]))
    assert has_element?(view, ~s(#{@modal} input[placeholder="Leave blank to keep it"]))

    renamed = unique("S")

    view
    |> form("#{@modal} form[phx-submit=save]", %{"form" => %{"code" => renamed, "pin" => ""}})
    |> render_submit()

    assert %{code: ^renamed, pin: "4321"} = Ash.get!(Secrets, secret.id)

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
    refute csv =~ "4321"
    refute csv =~ "Oct 19, 2026"
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
