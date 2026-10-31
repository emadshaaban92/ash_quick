defmodule AshQuick.Labels.Label do
  @moduledoc false
  # One `label` under a resource's `ash_quick do labels do ... end end`.
  defstruct [:name, :value, :label, :__spark_metadata__]
end
