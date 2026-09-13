defmodule AshQuick.Lookup.Verifier do
  @moduledoc false
  # Refuses to compile a resource whose *declared* lookup action cannot serve
  # the searches AshQuick runs through it — one that does not exist, is not a
  # read, does not take the declared search argument, or does not paginate
  # under a default limit.
  #
  # Scoped to a declaration the resource actually wrote, which is the whole
  # reason this can be a resource-level verifier at all. Whether a resource
  # needs a lookup action is not a fact about the resource: it depends on
  # something else pointing at it — a QuickView listing it, or a `belongs_to`
  # onto it rendered as a dropdown. Held over every resource carrying the
  # extension, this would demand an `:index` from the composite-keyed join
  # resources that will never be either.
  #
  # So it catches the mistake it can see from here — a typo, a rename, an
  # action that lost its `search` argument, its `pagination` block or the
  # `default_limit` the dropdowns lean on — and leaves absence to
  # `AshQuick.LiveView.QuickView.Options`, which knows what actually reaches
  # the resource and asks the same of it.

  use Spark.Dsl.Verifier

  alias AshQuick.Lookup.Contract
  alias AshQuick.Lookup.Declaration
  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    if Declaration.declared?(dsl_state) do
      verify_declared(dsl_state)
    else
      :ok
    end
  end

  defp verify_declared(dsl_state) do
    case Contract.check(dsl_state) do
      :ok ->
        :ok

      {:error, reason} ->
        module = Verifier.get_persisted(dsl_state, :module)

        {:error,
         Spark.Error.DslError.exception(
           module: module,
           path: [:ash_quick, :lookup, :action],
           message:
             Contract.message(
               module,
               Declaration.action(dsl_state),
               reason,
               "This resource declares a `lookup` action AshQuick cannot search through."
             )
         )}
    end
  end
end
