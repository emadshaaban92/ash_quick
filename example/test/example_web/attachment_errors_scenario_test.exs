defmodule ExampleWeb.AttachmentErrorsScenarioTest do
  @moduledoc """
  The resource's own validation failing on an attachment field, and where a
  person reads about it.

  Each action on `Example.Test.RequiredAttachments` refuses to save without a
  file: the single `:image` and the array `:documents`, on a create and on an
  update. The error belongs inside the field's section, and only once the form
  has been submitted: not on first render, and not because something else on
  the form changed while nothing was picked.

  A create form is the shape that hid it. A save with nothing picked leaves
  the field out of the params it is made with, and a field missing from them
  read as one nobody touched, so the error the save failed on never showed.
  The update tests passed before that fix: there the record's own value is put
  back under the key. They stay as pins for the same rule.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.RequiredAttachments

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  for {field, shape} <- [image: "a single attachment", documents: "an array of attachments"] do
    describe shape do
      @field field

      test "on a create form, says why a save with no file failed", %{conn: conn} do
        view = open(conn, "create?action=create_with_#{@field}")
        assert errors(view, @field) == []

        code = unique("R")
        save(view, %{"code" => code, "name" => "Scan"})

        assert errors(view, @field) == ["must be present"]
        refute code in saved_codes()
      end

      test "stays quiet while the rest of the form changes", %{conn: conn} do
        view = open(conn, "create?action=create_with_#{@field}")

        change(view, %{"code" => unique("R")})
        change(view, %{"name" => "Scan"})

        assert errors(view, @field) == []
      end

      test "on an update form, says why a save with no file failed", %{conn: conn} do
        record = Ash.create!(RequiredAttachments, %{code: unique("R"), name: "Scan"})

        view = open(conn, "#{record.id}/attach_#{@field}")
        assert errors(view, @field) == []

        save(view)

        assert errors(view, @field) == ["must be present"]
      end
    end
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, "/test/required_attachments/#{path}")
    view
  end

  defp change(view, params) do
    view |> form("form[phx-submit=save]") |> render_change(%{"form" => params})
  end

  defp save(view, params \\ %{}) do
    view |> form("form[phx-submit=save]", %{"form" => params}) |> render_submit()
  end

  defp saved_codes, do: RequiredAttachments |> Ash.read!() |> Enum.map(& &1.code)

  # The messages rendered inside the field's own section.
  defp errors(view, field) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("section[data-attachment-field='#{field}'] p.text-error")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
