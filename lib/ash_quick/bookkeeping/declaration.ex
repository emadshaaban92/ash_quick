defmodule AshQuick.Bookkeeping.Declaration do
  @moduledoc false
  # What a resource declared under `ash_quick do bookkeeping do ... end end`,
  # read the same way from a compiled resource and from the in-flight DSL state
  # — `Spark.Dsl.Extension.get_opt/4` takes either.
  #
  # Every reader has to carry the default itself: Spark hands back nothing for a
  # section the resource never entered, and all four fields default on. Holding
  # them here rather than at each call site is what keeps the DSL schema, the
  # verifier and `AshQuick.Info` from drifting apart — the schema reads them
  # from here too.
  #
  # Not `AshQuick.Bookkeeping`: Spark generates a module by that name for the
  # section's own imports, and defining one shadows the `bookkeeping` macro.

  @path [:ash_quick, :bookkeeping]
  @defaults [
    created_at: :created_at,
    updated_at: :updated_at,
    created_by: :created_by,
    updated_by: :updated_by
  ]

  # `:created_at` and `:updated_at` name attributes; `:created_by` and
  # `:updated_by` name relationships. Split because the verifier looks each
  # one up in a different place, and because the versioning ignore list needs
  # a relationship's *source attribute*, not its name.
  @timestamps [:created_at, :updated_at]
  @actors [:created_by, :updated_by]

  def defaults, do: @defaults
  def timestamps, do: @timestamps
  def actors, do: @actors

  def default(key), do: Keyword.fetch!(@defaults, key)

  @doc false
  # The declared name, or `nil` for a field declared absent. `false` is the
  # opt-out the DSL takes; every reader downstream wants `nil`, since a name
  # that is not there is not there.
  def field(dsl_or_resource, key) do
    case Spark.Dsl.Extension.get_opt(dsl_or_resource, @path, key, default(key)) do
      false -> nil
      name -> name
    end
  end

  @doc false
  # Whether a relationship pointing at `destination` is one to the actor.
  #
  # The name is not what decides: `belongs_to :created_by, Seller` is a
  # relationship to a seller, and stamping it with `relate_actor` would write a
  # user's id into a foreign key against another table. Held here because the
  # transformer and the verifier both have to answer it the same way — one to
  # decide whether to stamp, the other to refuse a resource where they disagree.
  #
  # A host configuring no `:actor_resource` has nothing an actor field could
  # point at, so nothing satisfies this.
  def actor_destination?(destination), do: destination == AshQuick.Config.actor_resource()
end
