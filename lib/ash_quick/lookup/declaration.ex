defmodule AshQuick.Lookup.Declaration do
  @moduledoc false
  # What a resource declared under `ash_quick do lookup do ... end end`, read
  # the same way from a compiled resource and from the in-flight DSL state —
  # `Spark.Dsl.Extension.get_opt/4` takes either.
  #
  # Every reader has to carry the default itself: Spark hands back nothing for a
  # section the resource never entered, and both defaults are what a resource
  # that says nothing gets. Holding them here rather than at each call site is
  # what keeps the DSL schema, the verifier, `AshQuick.Info` and the QuickView's
  # own check from drifting apart — the schema reads them from here too.
  #
  # Not `AshQuick.Lookup`: Spark generates a module by that name for the
  # section's own imports, and defining one shadows the `lookup` macro.

  @path [:ash_quick, :lookup]
  @action :index
  @search_argument :search

  def default_action, do: @action
  def default_search_argument, do: @search_argument

  def action(dsl_or_resource), do: get(dsl_or_resource, :action, @action)

  def search_argument(dsl_or_resource),
    do: get(dsl_or_resource, :search_argument, @search_argument)

  @doc false
  # Whether the resource entered the section at all, which is what scopes
  # `AshQuick.Lookup.Verifier` to an action someone actually named. Either
  # option answers it — Spark fills a section's schema defaults in once the
  # block is written — but both are asked so that neither can be renamed into
  # silently disarming the verifier.
  def declared?(dsl_or_resource) do
    Enum.any?([:action, :search_argument], &(not is_nil(get(dsl_or_resource, &1, nil))))
  end

  defp get(dsl_or_resource, option, default) do
    Spark.Dsl.Extension.get_opt(dsl_or_resource, @path, option, default)
  end
end
