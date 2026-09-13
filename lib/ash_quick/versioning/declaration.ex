defmodule AshQuick.Versioning.Declaration do
  @moduledoc false
  # What a resource declared under `ash_quick do versioning do ... end end`,
  # read the same way from a compiled resource and from the in-flight DSL state
  # — `Spark.Dsl.Extension.get_opt/4` takes either.
  #
  # Every reader has to carry the default itself: Spark hands back nothing for a
  # section the resource never entered, and versioning's defaults are what a
  # resource that says nothing gets. Holding them here rather than at each call
  # site is what keeps the DSL schema, the transformer, the verifier and
  # `AshQuick.Info` from drifting apart — the schema reads them from here too.
  #
  # Not `AshQuick.Versioning`: Spark generates a module by that name for the
  # section's own imports, and defining one shadows the `versioning` macro.

  @path [:ash_quick, :versioning]
  @enabled? true
  @attribute :version

  # What makes the column a lock counter, rather than a column that happens to
  # share the name. The transformer builds the attribute from this and the
  # verifier checks a resource's own against it, so neither can drift into
  # rejecting what the other adds.
  @counter [type: :integer, default: 1, allow_nil?: false, always_select?: true]

  def default_enabled?, do: @enabled?
  def default_attribute, do: @attribute
  def counter, do: @counter

  def enabled?(dsl_or_resource) do
    Spark.Dsl.Extension.get_opt(dsl_or_resource, @path, :enabled?, @enabled?)
  end

  def attribute(dsl_or_resource) do
    Spark.Dsl.Extension.get_opt(dsl_or_resource, @path, :attribute, @attribute)
  end
end
