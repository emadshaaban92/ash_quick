defmodule AshQuick.Print.Verifier do
  @moduledoc false
  # Refuses to compile a resource carrying `AshQuick.Print` where the print
  # could never be produced: on an action that hands back no record to print,
  # with options the change would refuse at run time, or in an application
  # without ChromicPDF to render it.
  #
  # Ash calls a change's `init/1` only when the action runs, so this is where a
  # print that cannot work is caught before anyone clicks it. It only sees
  # resources carrying the `AshQuick` extension; on any other the same mistakes
  # surface when the action runs.

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @printable [:create, :update]

  @impl true
  def verify(dsl_state) do
    module = Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> prints()
    |> Enum.flat_map(fn {path, types, opts} -> problems(types, opts) |> Enum.map(&{path, &1}) end)
    |> case do
      [] ->
        :ok

      [{path, message} | _] ->
        {:error, Spark.Error.DslError.exception(module: module, path: path, message: message)}
    end
  end

  # Every `AshQuick.Print` the resource carries, with the action types it runs
  # on: an action's own changes run on that action, a global one on what its
  # `on` names.
  defp prints(dsl_state) do
    in_actions =
      for %{name: name, type: type, changes: changes} <-
            Verifier.get_entities(dsl_state, [:actions]),
          %Ash.Resource.Change{change: {AshQuick.Print, opts}} <- changes,
          do: {[:actions, type, name], [type], opts}

    global =
      for %Ash.Resource.Change{change: {AshQuick.Print, opts}, on: on} <-
            Verifier.get_entities(dsl_state, [:changes]),
          do: {[:changes], List.wrap(on), opts}

    in_actions ++ global
  end

  defp problems(types, opts) do
    Enum.reject(
      [
        unprintable(types -- @printable),
        invalid(AshQuick.Print.init(opts)),
        unrenderable(AshQuick.Config.print_enabled?())
      ],
      &is_nil/1
    )
  end

  defp unprintable([]), do: nil

  defp unprintable(types) do
    """
    `AshQuick.Print` prints the record a create or update action returns, so \
    on #{Enum.map_join(types, " or ", &"a #{&1}")} action it would never print.
    """
  end

  defp invalid({:ok, _opts}), do: nil
  defp invalid({:error, message}), do: "`AshQuick.Print` #{message}."

  defp unrenderable(true), do: nil

  defp unrenderable(false) do
    """
    `AshQuick.Print` renders its PDF with ChromicPDF, which this application \
    does not have. Add `{:chromic_pdf, "~> 1.17"}` to its dependencies, and \
    `{:merge_pdf, "~> 0.5"}` too if a template returns more than one source.
    """
  end
end
