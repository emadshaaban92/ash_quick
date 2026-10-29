defmodule AshQuick.Labels.CatalogueTest do
  @moduledoc """
  The labels a QuickView and a nav read while they compile, and the `gettext`
  calls they are given for `mix gettext.extract` to find.

  Not async: one test configures a translator.
  """
  use ExUnit.Case, async: false

  alias AshQuick.Labels.Catalogue
  alias AshQuick.Test.LabelCatalogue.CrateLive.Quick
  alias AshQuick.Test.LabelCatalogue.Nav

  defmodule Shouting do
    @moduledoc false
    def translate(label), do: String.upcase(label)
  end

  setup do
    original = Application.fetch_env(:ash_quick, :label_translator)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:ash_quick, :label_translator, value)
        :error -> Application.delete_env(:ash_quick, :label_translator)
      end
    end)
  end

  defp labels, do: Catalogue.labels(Quick.__ash_quick_options__())

  test "reads a label of every kind, once each, in order" do
    labels = labels()

    # The titles, a column, the actions, an argument and its values.
    for label <- [
          "Crates",
          "Crate",
          "Code",
          "Seal",
          "Update",
          "Delete",
          "Create",
          "Seal Colour",
          "Red",
          "Blue"
        ] do
      assert label in labels
    end

    assert labels == labels |> Enum.uniq() |> Enum.sort()
  end

  # A `label:`, a saved filter, the `new_action_label` and a custom bulk
  # item are translated as they are drawn, like the labels AshQuick derives.
  test "reads the labels the host writes" do
    for label <- ["Shelf State", "Sealed ones", "Pack a Crate", "Weigh them", "Seal"] do
      assert label in labels()
    end
  end

  # A column through a relationship draws the destination's values.
  test "reads the values of a field a column reaches through a relationship" do
    assert "Empty" in labels()
    assert "Full" in labels()
  end

  # A destroy's form draws its inputs as a create's and an update's do.
  test "reads a destroy's inputs and their values" do
    assert "Scrap Reason" in labels()
    assert "Broken" in labels()
    assert "Lost" in labels()
  end

  # A column through an embedded attribute draws the embedded resource's
  # values, though no action accepts the attribute.
  test "reads the values of a field a column reaches through an embedded attribute" do
    assert "Matte" in labels()
    assert "Gloss" in labels()
  end

  test "reads them in English, whatever the translator says" do
    Application.put_env(:ash_quick, :label_translator, {Shouting, :translate})

    assert "Crates" in labels()
    refute "CRATES" in labels()
    # Only this process: the pages go on translating.
    assert AshQuick.Labels.translate("Crates") == "CRATES"
  end

  test "a QuickView is given a gettext call for each label it reads" do
    assert Quick.__ash_quick_labels__() == labels()
  end

  test "a nav is given one for each label it states, or takes from a path" do
    assert Nav.__ash_quick_labels__() == ["Crate Store", "Bays", "Warehouse"]
  end

  # A QuickView only the router names is labelled from its path when its
  # resource has no plural name, and only the route knows the path.
  test "a quick_view route is given one for the label of its path" do
    assert route_labels("/bays") == ["Bays"]
    assert route_labels("/") == []
  end

  defp route_labels(path) do
    quote do
      AshQuick.LiveView.Router.quick_view(unquote(path), SomeLive.Quick)
    end
    |> Macro.expand_once(%{__ENV__ | requires: [AshQuick.LiveView.Router | __ENV__.requires]})
    |> Macro.prewalk([], fn
      {{:., _, [_, :dgettext_noop_with_backend]}, _, [_, "labels", label]} = call, acc ->
        {call, [label | acc]}

      node, acc ->
        {node, acc}
    end)
    |> elem(1)
  end
end
