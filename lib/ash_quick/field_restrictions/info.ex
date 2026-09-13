defmodule AshQuick.FieldRestrictions.Info do
  @moduledoc """
  Introspection functions for the FieldRestrictions extension.
  """

  alias AshQuick.FieldRestrictions.Check

  def field_restrictions(resource) do
    Spark.Dsl.Extension.get_entities(resource, [:ash_quick, :field_restrictions])
  end

  def restricted_fields(resource, action_name) do
    resource
    |> field_restrictions()
    |> Enum.filter(fn restriction ->
      is_nil(restriction.on) or action_name in List.wrap(restriction.on)
    end)
  end

  def field_visible?(resource, action_name, field_name, %Check.Context{} = check_context) do
    resource
    |> restricted_fields(action_name)
    |> Enum.find(&(&1.field == field_name))
    |> case do
      nil -> true
      restriction -> check_passes?(restriction, check_context)
    end
  end

  defp check_passes?(%{check: {check_module, opts}}, check_context) do
    check_module.match?(check_context, opts)
  rescue
    _ -> false
  end
end
