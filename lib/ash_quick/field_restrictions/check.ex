defmodule AshQuick.FieldRestrictions.Check do
  @moduledoc """
  Behaviour for field restriction checks.

  Implement `match?/2` to determine whether a field should be visible/editable
  for a given actor and tenant. The callback receives a
  `%AshQuick.FieldRestrictions.Check.Context{}` struct and the opts
  configured on the restriction.

  ## Example

      defmodule MyApp.Checks.ActorHasPlatformRole do
        @behaviour AshQuick.FieldRestrictions.Check

        @impl true
        def match?(%{actor: %{platform_roles: roles}}, _opts) when is_list(roles) do
          roles != []
        end

        def match?(_, _), do: false
      end
  """

  defmodule Context do
    @moduledoc """
    The context passed to field restriction checks.
    """
    defstruct [:actor, :tenant]
  end

  @callback match?(context :: Context.t(), opts :: keyword()) :: boolean()
end
