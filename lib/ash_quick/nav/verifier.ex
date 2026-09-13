defmodule AshQuick.Nav.Verifier do
  @moduledoc false
  # Refuses to compile a nav whose declarations contradict each other.
  #
  # Only what is answerable from the declaration alone is checked here. Whether
  # a path is one the router serves, and whether any role can reach it, are
  # questions about two other modules — and a nav that reads the router while
  # it compiles is a cycle, since the router is what compiles the views the nav
  # names. Those belong to a test over the assembled application, not here.
  use Spark.Dsl.Verifier

  alias AshQuick.Nav.Entry
  alias AshQuick.Nav.Group
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    entities = Verifier.get_entities(dsl_state, [:nav])
    entries = Enum.filter(entities, &is_struct(&1, Entry))
    groups = Enum.filter(entities, &is_struct(&1, Group))

    with :ok <- verify_unique_entries(entries, dsl_state),
         :ok <- verify_unique_groups(groups, dsl_state),
         :ok <- verify_paths(entries, groups, dsl_state) do
      verify_non_empty_groups(groups, dsl_state)
    end
  end

  # A path is the identity of an entry — the thing groups reference and the
  # router resolves. Declaring it twice leaves two labels for one link and no
  # way to say which won.
  defp verify_unique_entries(entries, dsl_state) do
    case duplicates(Enum.map(entries, & &1.path)) do
      [] ->
        :ok

      paths ->
        error(dsl_state, """
        these paths are declared as an entry more than once: #{inspect(paths)}

        A path is one entry. To put it under two headings, name it from both \
        groups — a group holds path references, so the same path may appear in \
        any number of them.
        """)
    end
  end

  defp verify_unique_groups(groups, dsl_state) do
    case duplicates(Enum.map(groups, & &1.label)) do
      [] ->
        :ok

      labels ->
        error(dsl_state, """
        these group labels are declared more than once: #{inspect(labels)}

        A label is a heading in the sidebar and a tile in the grid, so two \
        groups sharing one render as two of each. Merge their paths into a \
        single group.
        """)
    end
  end

  # Paths are matched against the router and against the access-control lists
  # by comparing strings, so a missing leading slash is not a near miss — it
  # matches nothing anywhere, and renders as an entry that quietly never
  # appears.
  defp verify_paths(entries, groups, dsl_state) do
    declared = Enum.map(entries, & &1.path) ++ Enum.flat_map(groups, & &1.paths)

    case Enum.reject(declared, &String.starts_with?(&1, "/")) do
      [] ->
        :ok

      paths ->
        error(dsl_state, """
        these paths do not start with a slash: #{inspect(paths)}

        A nav path is written exactly as the router serves it.
        """)
    end
  end

  defp verify_non_empty_groups(groups, dsl_state) do
    case Enum.filter(groups, &(&1.paths == [])) do
      [] ->
        :ok

      groups ->
        error(dsl_state, """
        these groups name no paths: #{inspect(Enum.map(groups, & &1.label))}

        A group with nothing in it renders nowhere — the sidebar drops a \
        heading with no entries under it and the grid has no path to link a \
        tile to.
        """)
    end
  end

  defp duplicates(values) do
    values
    |> Enum.frequencies()
    |> Enum.filter(fn {_value, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
  end

  defp error(dsl_state, message) do
    {:error,
     Spark.Error.DslError.exception(
       module: Verifier.get_persisted(dsl_state, :module),
       path: [:nav],
       message: message
     )}
  end
end
