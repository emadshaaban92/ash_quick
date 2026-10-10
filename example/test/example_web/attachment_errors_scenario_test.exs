defmodule ExampleWeb.AttachmentErrorsScenarioTest do
  @moduledoc """
  The resource's own validation failing on an attachment field, and where a
  person reads about it.

  Each action on `Category` here refuses to save without a file: the single
  `:image` through `present/1`, the array `:documents` through
  `Example.Catalog.Validations.RequireFiles`. A save that brings none fails on
  that field alone, so an error not rendered inside the field's section is not
  rendered anywhere: the person presses Save and the page stays as it was.

  It shows only once the form has been submitted. A create form is the shape
  that hid it: nothing was picked, so the upload fold leaves the field out of
  the params the save is made with, and a field missing from the params reads
  as one the person never touched.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Catalog.Category

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  for {field, shape} <- [image: "a single attachment", documents: "an array of attachments"] do
    describe shape do
      @field field

      test "on a create form, says why a save with no file failed", %{conn: conn} do
        {:ok, view, _html} = live(conn, ~p"/categories/create?action=create_with_#{@field}")
        assert errors(view, @field) == []

        code = unique("C")
        save(view, %{"code" => code, "name" => "Tents"})

        assert errors(view, @field) == ["must be present"]
        assert {:error, _not_found} = Ash.get(Category, [code: code], authorize?: false)
      end

      test "on an update form, says why a save with no file failed", ctx do
        %{conn: conn, admin: admin} = ctx
        category = category(actor: admin)

        {:ok, view, _html} = live(conn, ~p"/categories/#{category.id}/attach_#{@field}")
        assert errors(view, @field) == []

        save(view)

        assert errors(view, @field) == ["must be present"]
      end
    end
  end

  defp save(view, params \\ %{}) do
    view |> form("form[phx-submit=save]", %{"form" => params}) |> render_submit()
  end

  # The messages rendered inside the field's own section.
  defp errors(view, field) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("section[data-attachment-field='#{field}'] p.text-error")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
