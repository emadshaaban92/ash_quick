defmodule ExampleWeb.ShadowedArgumentScenarioTest do
  @moduledoc """
  Attachment arguments named after a field of the record (issue #103).

  A save with nothing picked used to fill the argument with whatever the record
  held under the same name: `%Ash.NotLoaded{}` for a calculation the form never
  loads, which crashed the save, or a value of another type. Only the record's
  own attachment attribute keeps what it holds, and so does a single argument
  standing for it, which the form shows with its ✕; any other argument takes
  its default, and the form neither shows nor posts back the record's value as
  its own.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.ShadowedArguments

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  test "a save with no upload leaves the arguments to their defaults", %{conn: conn} do
    record = Ash.create!(ShadowedArguments, %{code: unique("S"), cover: "front.png"})

    {:ok, view, html} = live(conn, "/test/shadowed_arguments/#{record.id}/ship")
    refute html =~ "front.png"

    view |> form("form[phx-submit=save]") |> render_submit()

    assert Ash.get!(ShadowedArguments, record.id).shipped_with == 0
  end

  test "a single argument standing for the attachment attribute keeps the stored file", %{
    conn: conn
  } do
    record =
      Ash.create!(ShadowedArguments, %{code: unique("S"), photo: stored("kept-photo.jpg")})

    {:ok, view, _html} = live(conn, "/test/shadowed_arguments/#{record.id}/replace_photo")

    assert view
           |> element("input[type=hidden][name='form[photo]'][value*='kept-photo.jpg']")
           |> has_element?()

    view |> form("form[phx-submit=save]") |> render_submit()

    assert %{key: "private/shadowed/kept-photo.jpg"} =
             Ash.get!(ShadowedArguments, record.id).photo
  end

  test "the ✕ on a single argument standing for the attribute empties it", %{conn: conn} do
    record =
      Ash.create!(ShadowedArguments, %{code: unique("S"), photo: stored("cleared-photo.jpg")})

    {:ok, view, _html} = live(conn, "/test/shadowed_arguments/#{record.id}/replace_photo")

    view |> element("[phx-click*=remove-attachment]") |> render_click()

    refute view
           |> element("input[type=hidden][name='form[photo]'][value*='cleared-photo.jpg']")
           |> has_element?()

    view |> form("form[phx-submit=save]") |> render_submit()

    assert Ash.get!(ShadowedArguments, record.id).photo == nil
  end

  test "a list argument named after an attachment list starts from nothing", %{conn: conn} do
    record =
      Ash.create!(ShadowedArguments, %{code: unique("S"), scans: [stored("first-scan.jpg")]})

    {:ok, view, _html} = live(conn, "/test/shadowed_arguments/#{record.id}/add_scans")

    view |> form("form[phx-submit=save]") |> render_submit()

    assert [%{key: "private/shadowed/first-scan.jpg"}] =
             Ash.get!(ShadowedArguments, record.id).scans
  end

  defp stored(name),
    do: %AshQuick.AshTypes.Attachment.Value{key: "private/shadowed/#{name}", file_type: :image}
end
