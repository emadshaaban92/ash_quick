defmodule AshQuick.NavVerifierTest do
  @moduledoc """
  What the nav verifier will not let compile.

  Only contradictions inside the declaration are its business — a path is
  declared twice, two groups answer to one heading, a path is not a path, a
  group holds nothing. Whether a path is one the router serves, and whether
  any role can reach it, are questions about other modules and are settled in
  `AshQuick.LiveView.RouterTest`.

  Each probe is compiled through `AshQuick.Test.VerifierErrors`, which says how
  a test gets hold of the errors the compiler's own run reports.

  `async: false` because suppressing the compiler's own report means swapping
  the global `:standard_error` device.
  """
  use ExUnit.Case, async: false

  alias AshQuick.Test.VerifierErrors

  defp probe(body) do
    name = "NavProbe#{:erlang.unique_integer([:positive])}"

    source = """
    defmodule #{name} do
      use AshQuick.Nav

      nav do
        #{body}
      end
    end
    """

    VerifierErrors.compile(source)
    Module.concat([name])
  end

  defp message(body) do
    assert [%Spark.Error.DslError{} = error] = VerifierErrors.errors(probe(body))
    Exception.message(error)
  end

  test "the same path declared as two entries does not compile" do
    message =
      message("""
      entry "/products", label: "Products"
      entry "/products", label: "Catalogue"
      """)

    assert message =~ ~s|declared as an entry more than once: ["/products"]|

    # The way out has to be the group list, or a reader with one path under two
    # headings reaches for a second entry and gets this error back.
    assert message =~ "name it from both groups"
  end

  test "two groups under one label do not compile" do
    assert message("""
           group "Catalog", ~w(/products)
           group "Catalog", ~w(/brands)
           """) =~ ~s|group labels are declared more than once: ["Catalog"]|
  end

  test "a path that does not start with a slash does not compile" do
    # It is not a near miss: every match against the router and against the
    # access-control lists is a string comparison, so it matches nothing at all
    # and renders as an entry that quietly never appears.
    assert message(~s|entry "products"|) =~ ~s|do not start with a slash: ["products"]|
  end

  test "a group naming no paths does not compile" do
    # Written through an attribute because a literal `[]` in the second position
    # is read as the option list, and Spark rejects that as a missing argument
    # before any verifier runs.
    assert message("""
           @nothing []
           group "Empty", @nothing
           """) =~ ~s|name no paths: ["Empty"]|
  end

  test "a group naming a path no entry declares still compiles" do
    # Most QuickViews are discovered rather than declared, so a group referring
    # to a path nothing declares is the ordinary case, not a mistake.
    assert VerifierErrors.errors(probe(~s|group "Catalog", ~w(/products)|)) == []
  end
end
