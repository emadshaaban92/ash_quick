defmodule AshQuick.Check.Resources do
  @moduledoc false
  # The two things about a set of resources that no resource-level verifier can
  # say.
  #
  # A Spark verifier sees one resource's DSL and nothing else, which rules out
  # both of these by construction. It cannot notice a resource that never took
  # the extension on, because it never runs there. And it cannot notice that two
  # resources chose the same liveness prefix, because it is only ever looking at
  # one of them.
  #
  # What is deliberately *not* here: whether a resource turned versioning or
  # auditing off, and whether it has a lookup action. The first two are stated
  # in the DSL already — `enabled? false` is the decision, and asking for a
  # sentence beside it catches nothing. The third is not a fact about a resource
  # at all; `AshQuick.Lookup.Verifier` says why, and checking it here would
  # contradict it.

  alias AshQuick.Check.Finding
  alias AshQuick.Topics

  def run([]), do: {[], [{:resources, "no domains were given, so no resource was read"}]}

  def run(domains) do
    resources =
      domains
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.uniq()
      |> Enum.reject(&Ash.Resource.Info.embedded?/1)

    {missing_extension(resources) ++ colliding_prefixes(resources), []}
  end

  # Advisory: a resource without the extension is not broken, it is un-adopted.
  # The list is long on the day a project starts and shorter every week after,
  # which is a number to watch rather than one to block a deploy on.
  #
  # An embedded resource is dropped above rather than reported: it is a column's
  # shape, not a page, so it has no row to name in an audit entry and no list to
  # search.
  defp missing_extension(resources) do
    for resource <- resources, AshQuick not in Spark.extensions(resource) do
      %Finding{
        check: :missing_extension,
        subject: resource,
        severity: :advisory,
        message: """
        #{inspect(resource)} does not carry the AshQuick extension.

        Nothing here is broken — but nothing checks it either: it has no \
        declared label, no optimistic lock and no audit trail, and no verifier \
        runs over a resource that never took the extension on. A resource \
        nothing will ever render is a fine place to leave it.

            use Ash.Resource,
              extensions: [AshQuick]
        """
      }
    end
  end

  # Two resources publishing on one topic is the failure this task exists for:
  # each one's writes arrive at the other's pages, so a list refetches on a
  # record it does not hold and a details view reloads for a change to something
  # else entirely. Nothing raises, and the page that is wrong is not the page
  # that was edited.
  #
  # Only resources that publish are compared. `enabled? false` sends nothing, so
  # it collides with nothing.
  defp colliding_prefixes(resources) do
    resources
    |> Enum.filter(&Topics.enabled?/1)
    |> Enum.group_by(&Topics.collection/1)
    |> Enum.filter(fn {_prefix, sharing} -> length(sharing) > 1 end)
    |> Enum.sort()
    |> Enum.map(fn {prefix, sharing} -> collision(prefix, sharing) end)
  end

  defp collision(prefix, sharing) do
    %Finding{
      check: :colliding_liveness_prefix,
      subject: prefix,
      message: """
      #{Enum.map_join(sharing, " and ", &inspect/1)} all publish on \
      "#{prefix}".

      A QuickView subscribes to its resource's prefix, so each of these \
      resources' writes reach every one of the others' pages: a list refetches \
      over a record it does not hold, and a details view reloads for a change \
      to something else. Nothing raises, and the page that behaves oddly is \
      not the page anyone edited.

      The prefix defaults to the resource's `short_name`, so a collision means \
      two resources share one — or one of them declared the other's:

          ash_quick do
            liveness do
              prefix "catalog_products"
            end
          end
      """
    }
  end
end
