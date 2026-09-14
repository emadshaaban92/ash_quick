defmodule AshQuick.Audit.Declaration do
  @moduledoc false
  # What a resource declared under `ash_quick do audit do ... end end`, read the
  # same way from a compiled resource and from the in-flight DSL state —
  # `Spark.Dsl.Extension.get_opt/4` takes either.
  #
  # Every reader has to carry the default itself: Spark hands back nothing for a
  # section the resource never entered. Holding it here rather than at each call
  # site is what keeps the DSL schema, the transformer and `AshQuick.Info` from
  # drifting apart — the schema reads it from here too.
  #
  # Not `AshQuick.Audit`: Spark generates a module by that name for the
  # section's own imports, and defining one shadows the `audit` macro.

  @path [:ash_quick, :audit]
  @enabled? true
  @record_sensitive []
  @exclude_actions []

  def default_enabled?, do: @enabled?

  def enabled?(dsl_or_resource) do
    Spark.Dsl.Extension.get_opt(dsl_or_resource, @path, :enabled?, @enabled?)
  end

  @doc false
  # Whether AshQuick attaches `AshQuick.Audit.Change` to a resource's writes,
  # which is `enabled?` minus the two resources that cannot record themselves.
  # The single answer the transformer attaches on, and the one a compliance
  # report should quote — `enabled?` alone would call the audit store audited.
  def audits?(dsl_or_resource) do
    enabled?(dsl_or_resource) and not store?(dsl_or_resource) and
      not Ash.Resource.Info.embedded?(dsl_or_resource)
  end

  # An audit row names a row: an embedded resource has no identity of its own to
  # name, and the store writing its own writes would recurse.
  defp store?(dsl_or_resource) do
    module(dsl_or_resource) == store(dsl_or_resource)
  end

  defp module(dsl_state) when is_map(dsl_state) do
    Spark.Dsl.Transformer.get_persisted(dsl_state, :module)
  end

  defp module(resource) when is_atom(resource), do: resource

  @doc false
  # The resource an audited write is recorded in: this resource's own store, or
  # the host's. Nothing about a resource's compiled form depends on which, so
  # the fallback is read per write rather than baked in — but the *presence* of
  # one is settled at compile time by `AshQuick.Audit.Verifier`, which puts the
  # same `config.exs` constraint on the app-wide key as `:actor_resource`.
  def store(dsl_or_resource) do
    Spark.Dsl.Extension.get_opt(dsl_or_resource, @path, :store, nil) ||
      AshQuick.Config.audit_resource()
  end

  def default_record_sensitive, do: @record_sensitive

  # Read for every audited write, including one whose resource attaches the
  # change by hand without entering the section at all — hence the default.
  def record_sensitive(dsl_or_resource) do
    Spark.Dsl.Extension.get_opt(dsl_or_resource, @path, :record_sensitive, @record_sensitive)
  end

  def default_exclude_actions, do: @exclude_actions

  def exclude_actions(dsl_or_resource) do
    Spark.Dsl.Extension.get_opt(dsl_or_resource, @path, :exclude_actions, @exclude_actions)
  end
end
