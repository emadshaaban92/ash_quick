defmodule AshQuick.Labels.CatalogueTest do
  @moduledoc """
  What `AshQuick.Labels.Catalogue` reads, and what `mix ash_quick.gen.gettext`
  writes from it.

  Not async: the task reads the nav from application config, and one test
  configures a translator.
  """
  use ExUnit.Case, async: false

  alias AshQuick.Labels.Catalogue
  alias AshQuick.Test.LabelCatalogue.Nav
  alias Mix.Tasks.AshQuick.Gen.Gettext, as: GenGettext

  @view_source "test/support/label_catalogue_resources.ex"

  defmodule Shouting do
    @moduledoc false
    def translate(label), do: String.upcase(label)
  end

  setup do
    for key <- [:nav, :label_translator] do
      original = Application.fetch_env(:ash_quick, key)

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(:ash_quick, key, value)
          :error -> Application.delete_env(:ash_quick, key)
        end
      end)
    end

    Application.put_env(:ash_quick, :nav, Nav)
    :ok
  end

  defp labels, do: Catalogue.labels(Nav) |> Enum.map(&elem(&1, 0))

  test "reads a label of every kind, once each, in order" do
    labels = labels()

    # The nav, the titles, the columns, the saved filter, the create button,
    # a custom bulk item, the actions, an argument and its values.
    for label <- [
          "Crate Store",
          "Warehouse",
          "Crates",
          "Crate",
          "Code",
          "Shelf State",
          "Sealed ones",
          "Pack a Crate",
          "Weigh them",
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

  # A column through a relationship draws the destination's values.
  test "reads the values of a field a column reaches through a relationship" do
    assert "Empty" in labels()
    assert "Full" in labels()
  end

  test "reads them in English, whatever the translator says" do
    Application.put_env(:ash_quick, :label_translator, {Shouting, :translate})

    assert "Crates" in labels()
    refute "CRATES" in labels()
    # Only this process: the pages go on translating.
    assert AshQuick.Labels.translate("Crates") == "CRATES"
  end

  test "names the file that draws each label" do
    sources = Map.new(Catalogue.labels(Nav))

    assert sources["Crates"] == [@view_source]
    assert sources["Warehouse"] == [@view_source]
  end

  test "reads nothing without a nav" do
    assert Catalogue.labels(nil) == []
  end

  describe "mix ash_quick.gen.gettext" do
    @tag :tmp_dir
    test "writes a template gettext.extract leaves alone, and checks it", %{tmp_dir: dir} do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      GenGettext.run(["--priv", dir])
      pot = File.read!(Path.join(dir, "labels.pot"))

      assert pot =~ ~s(#: #{@view_source}\nmsgid "Crates"\nmsgstr ""\n)
      refute pot =~ "elixir-autogen"
      assert {:ok, _messages} = Expo.PO.parse_string(pot)

      assert GenGettext.run(["--priv", dir, "--check-up-to-date"]) == nil

      File.write!(Path.join(dir, "labels.pot"), String.replace(pot, ~s("Crates"), ~s("Boxes")))

      assert_raise Mix.Error, ~r/labels.pot is not up to date/, fn ->
        GenGettext.run(["--priv", dir, "--check-up-to-date"])
      end
    end

    @tag :tmp_dir
    test "writes another domain when told to", %{tmp_dir: dir} do
      Mix.shell(Mix.Shell.Process)
      on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

      GenGettext.run(["--priv", dir, "--domain", "ui"])

      assert File.exists?(Path.join(dir, "ui.pot"))
    end
  end
end
