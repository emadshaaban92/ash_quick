defmodule AshQuick.ReadOnlyFields.ReadOnlyField do
  @moduledoc false
  defstruct [:field, :writable_if, :on, :description, :__identifier__, :__spark_metadata__]
end
