defmodule AshQuick.ReadOnlyFields.Check do
  @moduledoc """
  Decides whether an actor may write a read-only field.

  A `read_only` entry names its check with `writable_if:`. AshQuick calls
  `match?/2` with a `%AshQuick.ReadOnlyFields.Check.Context{}`, holding the
  actor and tenant, and the opts given as `{Module, opts}` (`[]` when the
  module is given alone). `true` lets the actor write the field; `false`, or a
  raise, keeps it read-only for them.

  ## Example

      defmodule MyApp.Checks.ActorHasPlatformRole do
        @behaviour AshQuick.ReadOnlyFields.Check

        @impl true
        def match?(%{actor: %{platform_roles: roles}}, _opts) when is_list(roles) do
          roles != []
        end

        def match?(_, _), do: false
      end
  """

  defmodule Context do
    @moduledoc """
    The context passed to a read-only field's check: the actor and the tenant.
    """
    defstruct [:actor, :tenant]

    @type t :: %__MODULE__{actor: term(), tenant: term()}
  end

  @callback match?(context :: Context.t(), opts :: keyword()) :: boolean()
end
