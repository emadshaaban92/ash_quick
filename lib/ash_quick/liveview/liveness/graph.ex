defmodule AshQuick.LiveView.Liveness.Graph do
  @moduledoc false

  alias AshQuick.Topics

  @doc """
  Every resource record reachable from a fetched result.

  Returns `{watchable, skipped}` — `watchable` a list of `{resource, id}` whose
  resource publishes, `skipped` a `%{resource => count}` of the records found
  behind a resource that publishes nothing, or that has no `:id` to name a topic
  by.

  What materialized is the answer, which is why this walks the data rather than
  the view's declared `load:`. A module calculation's `load/3` dependencies stay
  on the struct, ids and all, so a view that asked for nothing but the
  calculation is still holding the records behind it: the graph is a superset of
  the declared one, and the surplus is exactly the part nobody declared.

  Recursion does not stop at a resource that publishes nothing, because a silent
  resource can stand between the page and records it does render — a join row
  between a parent and the children listed under it.

  The converse bounds it. An expression calculation or an aggregate is computed
  in SQL and materializes no records, so there is nothing here to find. That is
  a property of where the computation happened, not a hole in the walk, and it
  is what `:extra_records` exists for.
  """
  def walk(value) do
    {watchable, skipped} =
      value
      |> collect(MapSet.new())
      |> Enum.split_with(fn {resource, id} -> not is_map(id) and Topics.enabled?(resource) end)

    {watchable, Enum.frequencies_by(skipped, &elem(&1, 0))}
  end

  defp collect(%page{results: results}, seen) when page in [Ash.Page.Offset, Ash.Page.Keyset],
    do: collect(results, seen)

  defp collect(values, seen) when is_list(values), do: Enum.reduce(values, seen, &collect/2)

  defp collect(%resource{} = record, seen) do
    if Ash.Resource.Info.resource?(resource) do
      visit(record, resource, seen)
    else
      seen
    end
  end

  defp collect(_value, seen), do: seen

  # The `{resource, key}` set dedups and guards cycles at once: a child holding
  # its parent, whose children hold it back, terminates on its own.
  #
  # Recursion does not stop at a resource that publishes nothing, or a silent
  # join row would hide the children the page renders under it.
  defp visit(record, resource, seen) do
    case node_key(record, resource) do
      nil ->
        seen

      key ->
        if MapSet.member?(seen, key) do
          seen
        else
          resource
          |> related_values(record)
          |> Enum.reduce(MapSet.put(seen, key), &collect/2)
        end
    end
  end

  # A record is named by its `:id` when that is its primary key, which is what
  # a topic is built from. Anything else — a join row keyed by the two ids it
  # joins — is named by its primary-key values: it has no topic to watch, but
  # the records behind it still do. A map never passes for an `:id`, which is
  # how `walk/1` tells the two apart.
  #
  # A record whose key is not all there (one built but never persisted) is not
  # a node yet.
  defp node_key(record, resource) do
    case Ash.Resource.Info.primary_key(resource) do
      [:id] -> if id = Map.get(record, :id), do: {resource, id}
      [] -> nil
      fields -> if values = complete_key(record, fields), do: {resource, values}
    end
  end

  defp complete_key(record, fields) do
    values = Map.take(record, fields)
    if Enum.any?(values, fn {_field, value} -> is_nil(value) end), do: nil, else: values
  end

  # Relationships only. An embedded resource lives in an attribute and has no
  # topic of its own — no primary key either — since its changes arrive as an
  # update to the record holding it, which is also why a calculation's value is
  # not followed: a resource-typed calculation returns an embed.
  #
  # A calculation still puts records here: the relationships its `load/3`
  # declares are materialized on the struct, and this walks them like any other.
  defp related_values(resource, record) do
    Ash.Resource.Info.relationships(resource)
    |> Enum.map(&Map.get(record, &1.name))
  end
end
