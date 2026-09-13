defmodule AshQuick.PubSub.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @types [:create, :update, :destroy]

  @impl true
  def after?(_), do: true

  @impl true
  def transform(dsl_state) do
    if publish?(dsl_state) do
      {:ok, dsl_state |> put_options() |> put_publications() |> put_notifier()}
    else
      {:ok, dsl_state}
    end
  end

  defp publish?(dsl_state) do
    AshQuick.Config.endpoint() &&
      Transformer.get_option(dsl_state, [:ash_quick, :liveness], :enabled?, true)
  end

  # Whatever the resource wrote in its own `pub_sub` block stays: the module is
  # only defaulted, and the entities are appended to. The prefix is the one
  # option AshQuick owns, because the subscribe side derives it from
  # `AshQuick.Topics` and has no other way to know it.
  defp put_options(dsl_state) do
    dsl_state
    |> set_default([:pub_sub], :module, AshQuick.Config.endpoint())
    |> set_default([:pub_sub], :broadcast_type, :notification)
    |> set_default([:pub_sub], :delimiter, AshQuick.Topics.delimiter())
    |> Transformer.set_option([:pub_sub], :prefix, AshQuick.Topics.collection(dsl_state))
  end

  defp set_default(dsl_state, path, option, value) do
    case Transformer.get_option(dsl_state, path, option) do
      nil -> Transformer.set_option(dsl_state, path, option, value)
      _ -> dsl_state
    end
  end

  # Appended unconditionally. Publications from several `pub_sub` blocks
  # accumulate into one list, so a resource declaring its own publication for a
  # type it also gets here ends up with both — which is the point: a resource
  # wanting an extra topic shape for updates should not have to give up the
  # standard one every QuickView depends on.
  #
  # `[[:id, nil]]` publishes both `"product:<id>"` and the bare `"product"`: the
  # `nil` alternative drops the id segment. One publication feeds both a
  # row-scoped and a collection-wide subscriber.
  defp put_publications(dsl_state) do
    Enum.reduce(@types, dsl_state, fn type, dsl_state ->
      {:ok, publication} =
        Transformer.build_entity(Ash.Notifier.PubSub, [:pub_sub], :publish_all,
          type: type,
          topic: [[:id, nil]]
        )

      Transformer.add_entity(dsl_state, [:pub_sub], publication, type: :append)
    end)
  end

  # `notifiers:` is an extension list, which a transformer cannot add to — but
  # `Ash.Resource.Info.notifiers/1` reads `:simple_notifiers` alongside it, and
  # that is persisted state. So `extensions: [AshQuick]` is the whole opt-in: no
  # resource has to remember a second line for its liveness to work.
  defp put_notifier(dsl_state) do
    notifiers = Transformer.get_persisted(dsl_state, :simple_notifiers, [])

    if Ash.Notifier.PubSub in notifiers or
         Ash.Notifier.PubSub in Transformer.get_persisted(dsl_state, :notifiers, []) do
      dsl_state
    else
      Transformer.persist(dsl_state, :simple_notifiers, [Ash.Notifier.PubSub | notifiers])
    end
  end
end
