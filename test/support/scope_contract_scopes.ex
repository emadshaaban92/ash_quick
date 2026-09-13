defmodule AshQuick.Test.Scopes do
  @moduledoc """
  One scope per shape the provenance contract can be in.

  A host writes exactly one scope, so no single host drives every branch:
  "states its own timezone", "declares nothing beyond an actor" and "never
  heard of the contract" each need a scope of their own. These are those.

  They live in `test/support` rather than in a test file because protocols are
  consolidated in this environment: an implementation compiled after
  consolidation never dispatches, and `impl_for/1` — which
  `AshQuick.Scope.contract_violations/1` asks — would not see it either.
  """

  defmodule FullScope do
    @moduledoc "Declares every field the contract knows about."

    use AshQuick.Scope,
      actor: :user,
      tenant: :seller,
      real_actor: :behind,
      impersonating?: :pretending?,
      ip: :from,
      timezone: :tz,
      locale: :lang

    defstruct [:user, :seller, :behind, :from, :tz, :lang, pretending?: false]
  end

  defmodule MinimalScope do
    @moduledoc "Declares only an actor — the smallest thing the macro accepts."

    use AshQuick.Scope, actor: :user

    defstruct [:user]
  end

  defmodule DerivedScope do
    @moduledoc """
    Names a real actor but no `impersonating?` flag, so the answer is derived by
    comparing the two — the shape a host that tracks the real actor without
    tracking the state gets.
    """

    use AshQuick.Scope, actor: :user, real_actor: :behind

    defstruct [:user, :behind]
  end

  defmodule LegacyScope do
    @moduledoc """
    A scope written the way a host wrote one before the contract existed:
    `Ash.Scope.ToOpts` by hand, and nothing else.
    """

    defstruct [:user]

    defimpl Ash.Scope.ToOpts do
      def get_actor(%{user: user}), do: {:ok, user}
      def get_tenant(_scope), do: :error
      def get_context(_scope), do: :error
      def get_tracer(_scope), do: :error
      def get_authorize?(_scope), do: :error
    end
  end

  defmodule NotAScope do
    @moduledoc "Not a struct at all — what a host might point the check at by mistake."
  end
end
