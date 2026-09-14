defmodule Example.DataCase do
  @moduledoc """
  Tests that reach the database but not a page.

  Everything runs inside the Ecto SQL sandbox, so a test's writes are rolled
  back at the end of it. Prefer `async: true`: there is no global state in this
  application to serialize on.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Example.Repo

      import Example.DataCase
      import Example.Fixtures
    end
  end

  setup tags do
    Example.DataCase.setup_sandbox(tags)
    {:ok, Example.Fixtures.roles()}
  end

  @doc "Checks a sandbox connection out, shared when the test is not async."
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Example.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end
end
