defmodule AshQuick.ReadOnlyFields.StripReadOnlyFields do
  @moduledoc false
  use Ash.Resource.Change

  alias AshQuick.ReadOnlyFields.Check
  alias AshQuick.ReadOnlyFields.Info

  @impl true
  def change(changeset, _opts, context) do
    check_context = %Check.Context{actor: context.actor, tenant: context.tenant}
    action_name = changeset.action.name

    changeset.resource
    |> Info.read_only_fields(action_name)
    |> Enum.reject(fn read_only -> Info.check_passes?(read_only.writable_if, check_context) end)
    |> Enum.reduce(changeset, fn read_only, cs ->
      cs
      |> Ash.Changeset.clear_change(read_only.field)
      |> clear_argument(read_only.field)
    end)
  end

  # The same on the atomic path. An accepted input arrives there in
  # `changeset.atomics` rather than `changeset.attributes`, and
  # `Ash.Changeset.clear_change/2` clears both, so a read-only value is dropped
  # whichever path the write takes.
  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}

  defp clear_argument(changeset, field) do
    if Map.has_key?(changeset.arguments, field) do
      %{changeset | arguments: Map.delete(changeset.arguments, field)}
    else
      changeset
    end
  end
end
