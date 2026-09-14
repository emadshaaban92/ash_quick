defmodule Mix.Tasks.AshQuick.Gen.ResourceTest do
  @moduledoc """
  Taking a resource that already exists onto the extension.

  The resources are the compiled fixtures, and their source is handed to the
  test project under the same module names — `mix ash.extend` patches the file,
  and everything reported about the columns is read off the compiled form.
  """
  use ExUnit.Case, async: true

  import Igniter.Test

  @unadopted_path "lib/test/unadopted.ex"
  @named_path "lib/test/named.ex"

  @unadopted File.read!(Path.join(__DIR__, "../support/generator_unadopted.ex"))
  @named File.read!(Path.join(__DIR__, "../support/generator_named.ex"))

  defp extend(resource, files) do
    test_project(files: files)
    |> Igniter.compose_task("ash_quick.gen.resource", [resource])
  end

  defp unadopted, do: extend("AshQuick.Test.Gen.Unadopted", %{@unadopted_path => @unadopted})
  defp named, do: extend("AshQuick.Test.Gen.Named", %{@named_path => @named})

  describe "taking the extension on" do
    test "adds it to the resource, and queues the migration it implies" do
      igniter = unadopted()

      assert_has_patch(igniter, @unadopted_path, """
      + |    extensions: [AshQuick]
      """)

      assert_has_task(igniter, "ash.codegen", ["ash_quick_unadopted"])
    end

    test "does nothing to a resource that already carries it" do
      igniter = extend("AshQuick.Test.Gen.Widget", %{})

      assert_unchanged(igniter)
      assert_has_notice(igniter, &(&1 =~ "already carries AshQuick"))
    end
  end

  # The point of the task: `extensions: [AshQuick]` is one line and it is a
  # migration, so the columns are named before anyone runs one.
  describe "the report" do
    test "names every column the extension will add" do
      notice = notice(unadopted())

      assert notice =~ "adds 5 column(s)"

      for column <- ~w(version created_at updated_at created_by_id updated_by_id) do
        assert notice =~ "`#{column}`"
      end
    end

    test "names the actor resource the two references point at" do
      assert notice(unadopted()) =~ "a reference to AshQuick.Test.Actor"
    end

    # Add-if-absent: a resource that already declares the column keeps what it
    # wrote, and reporting it would send someone looking for a migration that is
    # not there.
    test "leaves out a column the resource already declares" do
      notice = notice(named())

      assert notice =~ "adds 4 column(s)"
      refute notice =~ "`created_at`"
      assert notice =~ "`updated_at`"
    end

    test "says where to turn one off, and that doing it later costs another migration" do
      notice = notice(unadopted())

      assert notice =~ "versioning do enabled? false end"
      assert notice =~ "another migration"
    end
  end

  # The extension refuses to compile a resource it cannot name a record by, and
  # that error arrives on the next `mix compile` rather than here — so it is
  # said here.
  describe "the display label" do
    test "is asked for when the resource has neither :name nor :display_name" do
      assert_has_warning(unadopted(), &(&1 =~ "no field to name a record by"))
    end

    test "is not asked for when the resource already has one" do
      refute Enum.any?(named().warnings, &(&1 =~ "no field to name a record by"))
    end
  end

  describe "what it refuses" do
    test "a name that resolves to nothing" do
      assert_has_issue(extend("Nope.NotHere", %{}), &(&1 =~ "does not exist"))
    end

    test "a module that is not a resource" do
      assert_has_issue(extend("AshQuick.Config", %{}), &(&1 =~ "not an Ash resource"))
    end
  end

  defp notice(igniter), do: Enum.join(igniter.notices, "\n")
end
