defmodule AshQuick.Labels.Help do
  @moduledoc false
  # One `help` under a resource's `ash_quick do labels do ... end end`.
  defstruct [:name, :help, :action, :__spark_metadata__]

  # The help text itself, trimmed. `false` is refused with a reason: help
  # comes only from `help` entries, so a field with none already draws none.
  @doc false
  def text(text) when is_binary(text), do: {:ok, String.trim(text)}

  def text(false) do
    {:error,
     "`false` is no help text. A form draws help only from `help` entries, " <>
       "so leave the entry out to draw none."}
  end

  def text(other), do: {:error, "expected the help text as a string, got: #{inspect(other)}"}
end
