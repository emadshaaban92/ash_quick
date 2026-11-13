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

  @path [:ash_quick, :versioning]
  @enabled? true
  @attribute :version

  # What makes the column a lock counter, rather than a column that happens to
  # share the name. The transformer builds the attribute from this and the
  # verifier checks a resource's own against it, so neither can drift into
  # rejecting what the other adds.
  #
  # `writable?: false` because only the lock may move it: `accept :*` would
  # otherwise take a submitted `version` and write it in place of `current + 1`.
  # The lock writes it with `force_change_attribute/3`, which ignores the flag.
  @counter [
    type: :integer,
    default: {__MODULE__, :initial, []},
    allow_nil?: false,
    always_select?: true,
    writable?: false
  ]

  # A function rather than `1`, for what it leaves in the struct: Ash gives a
  # struct field an attribute's literal default but `nil` for a function's, so
  # a hand-built `%Post{id: id}` holds `nil` — nobody's version — where a
  # literal would hold `1`, indistinguishable from a client that sent the
  # version it loaded. The lock reads the two apart from this. Creates still
  # start the counter at `1`, and the column's own default stays `1` — see
  # `AshQuick.Versioning.Transformer`.
  @doc """
  The counter's first version, `1`.

  Public, as `{AshQuick.Versioning.Declaration, :initial, []}`, for a
  resource that defines its counter itself: its `default` has to give `1`
  through a function, or `AshQuick.Versioning.Verifier` refuses it.
  """
  def initial, do: 1

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
