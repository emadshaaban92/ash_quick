defmodule AshQuick.Forms.Verifier do
  @moduledoc false
  # Refuses a `full_page` naming an action AshQuick never opens: one the
  # resource does not define, a read or a generic action, or a private one.
  # Each would leave the declaration doing nothing, with no sign of why.
  #
  # It only sees resources carrying the `AshQuick` extension, which are the
  # only ones that can declare it.

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @opened [:create, :update, :destroy]

  @impl true
  def verify(dsl_state) do
    actions = Verifier.get_entities(dsl_state, [:actions])

    dsl_state
    |> Verifier.get_option([:ash_quick, :forms], :full_page, [])
    |> Enum.find_value(&problem(&1, Enum.find(actions, fn action -> action.name == &1 end)))
    |> case do
      nil ->
        :ok

      message ->
        {:error,
         Spark.Error.DslError.exception(
           module: Verifier.get_persisted(dsl_state, :module),
           path: [:ash_quick, :forms, :full_page],
           message: message
         )}
    end
  end

  defp problem(name, nil) do
    "`full_page` names #{inspect(name)}, which is no action of this resource."
  end

  defp problem(name, %{type: type}) when type not in @opened do
    """
    `full_page` names #{inspect(name)}, #{kind(type)}. Only a create, an \
    update or a destroy opens in a form, so only one of those can open as a \
    full page.
    """
  end

  defp problem(name, %{public?: false}) do
    """
    `full_page` names #{inspect(name)}, which is private. AshQuick opens only \
    public actions, so it would never open as a page.
    """
  end

  defp problem(_name, _action), do: nil

  defp kind(:action), do: "a generic action"
  defp kind(type), do: "a #{type} action"
end
