defmodule AshQuick.ReadOnlyFields.Info do
  @moduledoc """
  Reads a resource's `read_only_fields` back.
  """

  alias AshQuick.ReadOnlyFields.Check

  @doc "Every `read_only` entry the resource declares."
  def read_only_fields(resource) do
    Spark.Dsl.Extension.get_entities(resource, [:ash_quick, :read_only_fields])
  end

  @doc "The `read_only` entries that cover `action_name`."
  def read_only_fields(resource, action_name) do
    resource
    |> read_only_fields()
    |> Enum.filter(fn read_only ->
      is_nil(read_only.on) or action_name in List.wrap(read_only.on)
    end)
  end

  @doc """
  Whether the actor and tenant in `check_context` may write `field_name` on
  `action_name`: true for a field no `read_only` entry covers there, and
  otherwise what the entry's `writable_if:` check answers. A check that raises
  answers false.
  """
  def writable?(resource, action_name, field_name, %Check.Context{} = check_context) do
    resource
    |> read_only_fields(action_name)
    |> Enum.find(&(&1.field == field_name))
    |> case do
      nil -> true
      read_only -> check_passes?(read_only.writable_if, check_context)
    end
  end

  @doc false
  def check_passes?({check_module, opts}, check_context) do
    check_module.match?(check_context, opts)
  rescue
    _ -> false
  end
end
