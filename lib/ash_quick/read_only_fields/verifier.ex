defmodule AshQuick.ReadOnlyFields.Verifier do
  @moduledoc false
  # Refuses a `read_only` entry that would protect nothing: a field no create,
  # update or destroy it covers takes as input (a misspelt name, an attribute
  # no action accepts, or a private argument, which Ash never takes as input),
  # or an `on:` naming a read or generic action, one the resource lacks, or one
  # that does not take the field. Each would leave the field writable, or
  # the entry doing nothing, with no sign of why. And it refuses a covered
  # action whose own changes run before the strip (see `order_problem/2`).
  #
  # It only sees resources carrying the `AshQuick` extension, which are the
  # only ones that can declare it.

  use Spark.Dsl.Verifier

  alias AshQuick.ReadOnlyFields.Info
  alias AshQuick.ReadOnlyFields.StripReadOnlyFields
  alias Spark.Dsl.Verifier

  @covered [:create, :update, :destroy]

  @impl true
  def verify(dsl_state) do
    actions = Verifier.get_entities(dsl_state, [:actions])

    dsl_state
    |> Info.read_only_fields()
    |> Enum.find_value(fn read_only ->
      with message when is_binary(message) <-
             problem(read_only, actions) || order_problem(read_only, actions) do
        {read_only, message}
      end
    end)
    |> case do
      nil ->
        :ok

      {read_only, message} ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:ash_quick, :read_only_fields, :read_only, read_only.field],
           message: message
         )}
    end
  end

  defp problem(%{field: field, on: nil}, actions) do
    if not Enum.any?(actions, &(&1.type in @covered and takes?(&1, field))) do
      """
      `read_only #{inspect(field)}` names a field no create, update or destroy \
      takes as input, neither an accepted attribute nor a public argument, so \
      it would keep nothing read-only. Check the name, or accept the field on \
      an action.
      """
    end
  end

  defp problem(%{field: field, on: on}, actions) do
    Enum.find_value(List.wrap(on), fn name ->
      on_problem(field, name, Enum.find(actions, &(&1.name == name)))
    end)
  end

  defp on_problem(field, name, nil) do
    "`read_only #{inspect(field)}` is `on:` #{inspect(name)}, which is no action of this resource."
  end

  defp on_problem(field, name, %{type: type}) when type not in @covered do
    """
    `read_only #{inspect(field)}` is `on:` #{inspect(name)}, #{kind(type)}. \
    Only a create, an update or a destroy writes a field, so only those can \
    keep one read-only.
    """
  end

  defp on_problem(field, name, action) do
    if not takes?(action, field) do
      """
      `read_only #{inspect(field)}` is `on:` #{inspect(name)}, which takes no \
      #{inspect(field)} as input, neither an accepted attribute nor a public \
      argument, so it would keep nothing read-only there. Check the name, or \
      leave #{inspect(name)} out of `on:`.
      """
    end
  end

  # The transformer puts the strip first among each action's changes, so a
  # refused input is gone before any of them reads it. An action another
  # extension adds after the transformer has run carries no strip of its own,
  # and only the global one runs, after its changes: one of those changes could
  # still write a refused input. So a covered action that takes the field and
  # runs any change before the strip does not compile.
  defp order_problem(%{field: field, on: on}, actions) do
    actions
    |> Enum.filter(&(&1.type in @covered and (is_nil(on) or &1.name in List.wrap(on))))
    |> Enum.find(&(takes?(&1, field) and changes_before_strip?(&1)))
    |> case do
      nil ->
        nil

      action ->
        """
        `read_only #{inspect(field)}` covers #{inspect(action.name)}, which runs \
        changes before AshQuick's read-only strip: another extension added the \
        action, or put a change ahead of the strip, after AshQuick's \
        transformer ran. Those changes could still write a refused \
        #{inspect(field)}. Name the actions the entry covers with \
        `on:` and leave #{inspect(action.name)} out, or keep \
        #{inspect(field)} out of that action.
        """
    end
  end

  defp changes_before_strip?(%{changes: []}), do: false

  defp changes_before_strip?(%{changes: [first | _]}) do
    not match?(%{change: {StripReadOnlyFields, _}}, first)
  end

  # A private argument is never taken as input, so it counts for nothing.
  defp takes?(action, field) do
    field in (action.accept || []) or
      Enum.any?(action.arguments, &(&1.name == field and &1.public?))
  end

  defp kind(:action), do: "a generic action"
  defp kind(type), do: "a #{type} action"
end
