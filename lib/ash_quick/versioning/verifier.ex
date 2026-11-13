defmodule AshQuick.Versioning.Verifier do
  @moduledoc false
  # Refuses to compile a resource whose locked attribute is not a lock counter.
  #
  # `AshQuick.Versioning.Transformer` adds the attribute only when the resource
  # does not already define one by that name, so a resource that owns a
  # `:version` meaning something else keeps its own definition and the lock
  # silently operates on it — filtering on a value it does not control and
  # incrementing it on every write. An extension that gives a resource a
  # `:version` meaning its event's schema version is exactly such a column; the
  # moment that resource takes on AshQuick, this is what stops it.
  #
  # Checked after the transformer, so a column AshQuick added passes by
  # construction and only a foreign one can fail.
  use Spark.Dsl.Verifier

  alias AshQuick.Versioning.Declaration
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    if Declaration.enabled?(dsl_state) do
      name = Declaration.attribute(dsl_state)

      dsl_state
      |> Ash.Resource.Info.attribute(name)
      |> mismatches()
      |> case do
        [] -> :ok
        mismatches -> {:error, error(dsl_state, name, mismatches)}
      end
    else
      :ok
    end
  end

  # `{option, actual, expected}` for every way the column differs, so the message
  # does not have to look the attribute up again to say what it found.
  defp mismatches(attribute) do
    expected()
    |> Enum.map(fn {option, expected} -> {option, Map.get(attribute, option), expected} end)
    |> Enum.reject(fn {option, actual, expected} ->
      actual == expected or same?(option, actual)
    end)
  end

  # A default of the resource's own passes when it is a function giving the
  # same first version: what matters is that the struct holds `nil` for a
  # record nobody loaded, which a literal `1` would not.
  defp same?(:default, default) when is_function(default, 0),
    do: default.() == Declaration.initial()

  defp same?(:default, {module, function, args}) when is_atom(module) and is_list(args),
    do: apply(module, function, args) == Declaration.initial()

  defp same?(_option, _actual), do: false

  # The shape the transformer builds, with `:type` resolved the way a compiled
  # attribute carries it — `:integer` on the way in, `Ash.Type.Integer` back out.
  defp expected do
    Keyword.update!(Declaration.counter(), :type, &Ash.Type.get_type/1)
  end

  # A counter that is otherwise right but defaults to a literal `1` is the
  # likeliest mismatch, from before the default became a function, so it gets
  # its own way out.
  defp default_hint(mismatches) do
    if Enum.any?(mismatches, &match?({:default, actual, _} when is_integer(actual), &1)) do
      """


      A literal default leaves it in every hand-built struct, where the lock \
      cannot tell `%Post{id: id}` from a client's own version 1. Drop the \
      attribute and let AshQuick add it, or default it with \
      `default: {AshQuick.Versioning.Declaration, :initial, []}`.\
      """
    else
      ""
    end
  end

  defp error(dsl_state, name, mismatches) do
    module = Verifier.get_persisted(dsl_state, :module)

    Spark.Error.DslError.exception(
      module: module,
      path: [:ash_quick, :versioning],
      message: """
      #{inspect(module)} already defines `#{name}`, but not as an optimistic-lock counter:

      #{Enum.map_join(mismatches, "\n", fn {option, actual, expected} -> "  #{option} is #{inspect(actual)}, expected #{inspect(expected)}" end)}

      Versioning would filter writes on that column and increment it, which is \
      almost certainly not what it means here.#{default_hint(mismatches)}

      Lock on a different column:

          ash_quick do
            versioning do
              attribute :lock_version
            end
          end

      or turn versioning off for this resource:

          ash_quick do
            versioning do
              enabled? false
            end
          end
      """
    )
  end
end
