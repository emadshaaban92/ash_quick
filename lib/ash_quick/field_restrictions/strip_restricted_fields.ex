defmodule AshQuick.FieldRestrictions.StripRestrictedFields do
  @moduledoc false
  use Ash.Resource.Change

  alias AshQuick.FieldRestrictions.Check
  alias AshQuick.FieldRestrictions.Info

  @impl true
  def change(changeset, _opts, context) do
    check_context = %Check.Context{actor: context.actor, tenant: context.tenant}
    action_name = changeset.action.name

    changeset.resource
    |> Info.restricted_fields(action_name)
    |> Enum.reject(fn restriction -> check_passes?(restriction.check, check_context) end)
    |> Enum.reduce(changeset, fn restriction, cs ->
      cs
      |> Ash.Changeset.clear_change(restriction.field)
      |> clear_argument(restriction.field)
    end)
  end

  defp check_passes?({check_module, check_opts}, check_context) do
    check_module.match?(check_context, check_opts)
  rescue
    _ -> false
  end

  defp clear_argument(changeset, field) do
    if Map.has_key?(changeset.arguments, field) do
      %{changeset | arguments: Map.delete(changeset.arguments, field)}
    else
      changeset
    end
  end
end
