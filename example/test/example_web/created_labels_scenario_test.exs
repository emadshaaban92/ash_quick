defmodule ExampleWeb.CreatedLabelsScenarioTest do
  @moduledoc """
  A list of names a `manage_relationship` change looks up by `value_is_key`
  and creates when nothing matches: `Example.Catalog.Product`'s `:labels`.
  The product form's picker offers the labels there are, keyed by name, and
  the typed text as an Add row to whoever may create a label, which is an
  admin (`Example.Catalog.Label`). The name is a `ci_string`, so the row
  ignores case, as the lookup does.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  alias Example.Catalog.Label
  alias ExampleWeb.PickerDriver, as: Picker

  @picker "form_labels-picker"

  defp label!(name, actor), do: Ash.create!(Label, %{name: name}, actor: actor)

  defp labels_of(product) do
    product
    |> Ash.load!([labels: [:name]], authorize?: false)
    |> Map.fetch!(:labels)
    |> Enum.map(&to_string(&1.name))
    |> Enum.sort()
  end

  defp label_names do
    Label |> Ash.read!(authorize?: false) |> Enum.map(&to_string(&1.name)) |> Enum.sort()
  end

  defp save(view), do: view |> form("form[phx-submit=save]") |> render_submit()

  describe "an admin" do
    setup %{conn: conn, admin: admin} do
      {:ok, conn: log_in(conn, admin), product: product(actor: admin)}
    end

    test "relates a label there is and adds a new one in one save", ctx do
      %{conn: conn, product: product} = ctx
      label!("Outdoor", ctx.admin)

      {:ok, view, _html} = live(conn, ~p"/products/#{product.id}/update")

      assert Picker.search(view, @picker, "Out") == ["Outdoor", ~s(Add "Out")]
      Picker.pick(view, @picker, "Outdoor")

      assert Picker.search(view, @picker, "Kayak") == [~s(Add "Kayak")]
      Picker.pick(view, @picker, ~s(Add "Kayak"))

      assert has_element?(view, "##{@picker} [data-part=tag][data-new]", "Kayak")
      refute has_element?(view, "##{@picker} [data-part=tag][data-value=Outdoor][data-new]")

      assert Picker.posted(view, @picker) == [
               {"form[labels][]", "Outdoor"},
               {"form[labels][]", "Kayak"}
             ]

      save(view)

      assert labels_of(product) == ["Kayak", "Outdoor"]
      assert label_names() == ["Kayak", "Outdoor"]
    end

    test "the update form starts from the names the product has", ctx do
      %{conn: conn, product: product, admin: admin} = ctx
      label!("Outdoor", ctx.admin)

      product
      |> Ash.Changeset.for_update(:update, %{labels: ["Outdoor"]}, actor: admin)
      |> Ash.update!()

      {:ok, view, _html} = live(conn, ~p"/products/#{product.id}/update")

      assert Picker.picked(view, @picker) == ["Outdoor"]
      assert Picker.posted(view, @picker) == [{"form[labels][]", "Outdoor"}]
      refute has_element?(view, "##{@picker} [data-part=tag][data-new]")

      Picker.remove(view, @picker, "Outdoor")
      save(view)

      assert labels_of(product) == []
    end

    test "typed in another case, a label there is offers no Add row", ctx do
      %{conn: conn, product: product} = ctx
      label!("Kayak", ctx.admin)

      {:ok, view, _html} = live(conn, ~p"/products/#{product.id}/update")

      assert Picker.search(view, @picker, "kAYAK") == ["Kayak"]
    end

    test "a name posted in another case relates the label there is", ctx do
      %{conn: conn, product: product} = ctx
      label!("Kayak", ctx.admin)

      {:ok, view, _html} = live(conn, ~p"/products/#{product.id}/update")

      view
      |> form("form[phx-submit=save]")
      |> render_submit(%{"form" => %{"labels" => ["kAYAK"]}})

      assert labels_of(product) == ["Kayak"]
      assert label_names() == ["Kayak"]
    end

    test "the create form adds new labels too", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/products/create")

      assert Picker.search(view, @picker, "Kayak") == [~s(Add "Kayak")]
    end
  end

  describe "an editor, who may change a product but not create a label" do
    setup %{conn: conn, admin: admin, editor: editor} do
      {:ok, conn: log_in(conn, editor), product: product(actor: admin)}
    end

    test "is offered the labels there are and no Add row", ctx do
      %{conn: conn, product: product} = ctx
      label!("Outdoor", ctx.admin)

      {:ok, view, _html} = live(conn, ~p"/products/#{product.id}/update")

      assert Picker.search(view, @picker, "Kayak") == []
      assert render(view) =~ "No matches"

      assert Picker.search(view, @picker, "Out") == ["Outdoor"]
      Picker.pick(view, @picker, "Outdoor")
      save(view)

      assert labels_of(product) == ["Outdoor"]
    end

    test "a new name posted anyway is refused, and creates nothing", ctx do
      %{conn: conn, product: product} = ctx

      {:ok, view, _html} = live(conn, ~p"/products/#{product.id}/update")

      html =
        view
        |> form("form[phx-submit=save]")
        |> render_submit(%{"form" => %{"labels" => ["Kayak"]}})

      assert html =~ "You don&#39;t have permission to do that."
      assert has_element?(view, "##{@picker}")
      assert labels_of(product) == []
      assert label_names() == []
    end
  end

  test "an id list is never offered an Add row, though its change creates", ctx do
    %{conn: conn, admin: admin} = ctx
    label = Ash.create!(Example.Test.PickedLabels.Label, %{name: unique("Label")})

    {:ok, view, _html} = live(log_in(conn, admin), "/test/created_picks/create")

    # The lookup action takes no search, so typing narrows nothing: what
    # matters is that nothing typed is offered as new.
    # The labels are in ETS, shared with every other test running alongside.
    assert label.name in Picker.search(view, "form_picks-picker", "Nothing like it")
    refute has_element?(view, "#form_picks-picker-listbox [data-new]")
  end

  test "an Add row is offered as the create will run, without the form's source", ctx do
    %{conn: conn, admin: admin} = ctx
    alias Example.Test.SourcedLabels
    code = unique("S")
    name = unique("Label")

    {:ok, view, _html} = live(log_in(conn, admin), "/test/sourced_labels/create")

    assert Picker.search(view, "form_labels-picker", name) == [~s(Add "#{name}")]
    Picker.pick(view, "form_labels-picker", ~s(Add "#{name}"))

    view
    |> form("form[phx-submit=save]")
    |> render_submit(%{"form" => %{"code" => code}})

    record =
      SourcedLabels
      |> Ash.Query.filter(code == ^code)
      |> Ash.read_one!(authorize?: false)
      |> Ash.load!([labels: [:name]], authorize?: false)

    assert Enum.map(record.labels, & &1.name) == [name]
  end
end
