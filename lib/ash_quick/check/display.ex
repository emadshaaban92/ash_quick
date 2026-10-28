defmodule AshQuick.Check.Display do
  @moduledoc false
  # Each resource's `display` path held to the router it names a page on.
  #
  # The resource compiles before the router, so nothing at compile time can say
  # whether the path it declared is a page at all. A wrong one is a link to a
  # route that is not there, or to some other resource's page; nothing raises
  # until a reader clicks it.

  alias AshQuick.Check.Finding
  alias AshQuick.Nav.Info

  def run(domains, router, actor_resource)

  def run([], _router, _actor_resource), do: {[], []}

  def run(_domains, nil, _actor_resource),
    do: {[], [{:display, "no router was given, so no display path was read"}]}

  def run(domains, router, actor_resource) do
    resources =
      domains
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.uniq()
      |> Enum.filter(&(AshQuick in Spark.extensions(&1)))

    served = router |> Info.discovered() |> Map.new()

    findings =
      Enum.flat_map(resources, fn resource ->
        check(
          resource,
          AshQuick.Info.display_path(resource),
          Info.details_base_paths(resource, router),
          actor_resource,
          served
        )
      end)

    {findings, []}
  end

  # Only a writer is linked today, so only the actor resource is asked to
  # choose: a page of any other resource served twice is linked by nothing,
  # and an advisory nothing reads teaches a host to skip the report.
  defp check(resource, nil, [_, _ | _] = paths, resource, _served) do
    [
      %Finding{
        check: :ambiguous_display_path,
        subject: resource,
        severity: :advisory,
        message: """
        #{inspect(resource)} is served with a details route at \
        #{join(paths)}, and declares none of them as its own.

        Nothing is broken: a page that would link one of its records — the \
        writer in a details header — names it without a link instead. Say \
        which page a record opens at:

            ash_quick do
              display do
                path "#{hd(paths)}"
              end
            end
        """
      }
    ]
  end

  defp check(_resource, nil, _paths, _actor_resource, _served), do: []

  defp check(resource, declared, paths, _actor_resource, served) do
    if declared in paths do
      []
    else
      [
        %Finding{
          check: :unrouted_display_path,
          subject: resource,
          message: """
          #{inspect(resource)} declares `display path "#{declared}"`, but no \
          QuickView over it is served there with a details route.

          #{declared}/<id> #{answered_by(Map.get(served, declared), resource)}, so no page \
          links one of its records.#{suggestion(paths)}
          """
        }
      ]
    end
  end

  defp answered_by(nil, _resource), do: "is answered by nothing"

  defp answered_by(resource, resource),
    do: "is answered by nothing: its page has no details route"

  defp answered_by(other, _resource), do: "is #{inspect(other)}'s page, not its own"

  defp suggestion([]), do: ""
  defp suggestion(paths), do: " It is served with a details route at #{join(paths)}."

  defp join([path]), do: path
  defp join(paths), do: "#{paths |> Enum.drop(-1) |> Enum.join(", ")} and #{List.last(paths)}"
end
