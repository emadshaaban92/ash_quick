defmodule AshQuick.DisplayTest do
  @moduledoc """
  The `display` options a resource cannot compile with.

  Each is a field name or a path a page reads at render time, so a wrong one
  is refused while the resource compiles rather than rendered as nothing.
  """
  use ExUnit.Case, async: true

  defp compile(display) do
    module = :"Elixir.DisplayProbe#{:erlang.unique_integer([:positive])}"

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use Ash.Resource,
        domain: nil,
        validate_domain_inclusion?: false,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshQuick]

      attributes do
        uuid_primary_key :id
        attribute :name, :string, public?: true
        attribute :email, :string, public?: true
      end

      relationships do
        belongs_to :parent, __MODULE__
      end

      actions do
        defaults [:read]
      end

      ash_quick do
        display do
          #{display}
        end
      end
    end
    """)

    module
  end

  test "a hint naming a field is accepted and read back" do
    module = compile("hint :email")

    assert AshQuick.Info.display_hint(module) == :email

    assert AshQuick.Info.display_hint_value(struct(module, email: "a@example.com")) ==
             "a@example.com"
  end

  test "a hint naming no field does not compile" do
    assert_raise Spark.Error.DslError, ~r/`hint :nope` names no attribute/, fn ->
      compile("hint :nope")
    end
  end

  test "a hint naming a relationship does not compile" do
    assert_raise Spark.Error.DslError, ~r/`hint :parent` names no attribute/, fn ->
      compile("hint :parent")
    end
  end

  test "a path that is not a base path does not compile" do
    # Relative; a page at "/users//<id>"; a link to another host; a query the
    # id would be appended to.
    for path <- ["users", "/", "/users/", "//cdn.example", "/users?tab=all", "/a//b"] do
      assert_raise Spark.Error.DslError, ~r/is not a QuickView base path/, fn ->
        compile(~s(path #{inspect(path)}))
      end
    end
  end

  test "a nested base path compiles" do
    assert AshQuick.Info.display_path(compile(~s(path "/admin/people"))) == "/admin/people"
  end

  test "a declared path is read back" do
    module = compile(~s(path "/people"))

    assert AshQuick.Info.display_path(module) == "/people"
  end
end
