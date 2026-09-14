defmodule AshQuick.Check.Resources do
  @moduledoc false
  # The half of the compliance check that reads resources rather than routes.
  #
  # Everything here is something the compile-time verifiers deliberately cannot
  # say. A verifier only runs over a resource that took the extension on, so the
  # resource most likely to be non-compliant — the one that never added it — is
  # invisible to every one of them. And the three declarations below are
  # *decisions*: versioning and audit are on by default and turning either off
  # is allowed, so no verifier may refuse it; a lookup action is only required
  # once something points at the resource, so `AshQuick.Lookup.Verifier` checks
  # a declared one and leaves absence alone.
  #
  # Each is therefore reported, not raised, and each stops being reported once
  # the resource says why.

  alias AshQuick.Audit.Declaration, as: Audit
  alias AshQuick.Check.Finding
  alias AshQuick.Lookup.Contract
  alias AshQuick.Lookup.Declaration, as: Lookup
  alias AshQuick.Versioning.Declaration, as: Versioning

  def run([]), do: {[], [{:resources, "no domains were given, so no resource was read"}]}

  def run(domains) do
    findings =
      domains
      |> Enum.flat_map(&Ash.Domain.Info.resources/1)
      |> Enum.uniq()
      |> Enum.flat_map(&check/1)

    {findings, []}
  end

  # An embedded resource is a column's shape, not a page: it has no row to name
  # in an audit entry, no list to search and no lock of its own, so none of the
  # four below is a question about it.
  defp check(resource) do
    cond do
      Ash.Resource.Info.embedded?(resource) -> []
      AshQuick not in Spark.extensions(resource) -> [missing_extension(resource)]
      true -> versioning(resource) ++ audit(resource) ++ lookup(resource)
    end
  end

  defp missing_extension(resource) do
    %Finding{
      check: :missing_extension,
      subject: resource,
      message: """
      #{inspect(resource)} does not carry the AshQuick extension.

      Nothing else in this report can be held over it: it has no declared \
      label, no searchable read, no optimistic lock and no audit trail, and \
      none of AshQuick's verifiers runs over a resource that never took the \
      extension on. The gap surfaces the day a page is pointed at it.

          use Ash.Resource,
            extensions: [AshQuick]
      """
    }
  end

  defp versioning(resource) do
    if Versioning.enabled?(resource) or Versioning.reason(resource) do
      []
    else
      [
        %Finding{
          check: :unversioned,
          subject: resource,
          message: """
          #{inspect(resource)} turns versioning off and states no reason.

          Without the optimistic lock, two people editing the same record from \
          two tabs both save: the second write lands on top of the first, and \
          neither is told. That is a fine trade for a resource only the system \
          writes, or one whose fields nobody contends — but it is a decision, \
          so record it:

              ash_quick do
                versioning do
                  enabled? false
                  reason "Append-only; every row is written once by the system."
                end
              end
          """
        }
      ]
    end
  end

  defp audit(resource) do
    if Audit.enabled?(resource) or Audit.reason(resource) do
      []
    else
      [
        %Finding{
          check: :unaudited,
          subject: resource,
          message: """
          #{inspect(resource)} turns auditing off and states no reason.

          Nothing records who changed one of its rows, or what it held before. \
          The absence is discovered by whoever needed the log and did not have \
          it, which is always after the fact — so if it is the right answer \
          here, say why:

              ash_quick do
                audit do
                  enabled? false
                  reason "The audit store itself; a row per write would recurse."
                end
              end
          """
        }
      ]
    end
  end

  # `AshQuick.Lookup.Verifier`'s blind spot, and only that: it checks an action
  # the resource *declared*, because whether a resource needs one at all depends
  # on something else pointing at it. This asks the same question of every
  # resource carrying the extension, so a missing `:index` is reported now
  # rather than the day a dropdown is pointed here.
  defp lookup(resource) do
    case Contract.check(resource) do
      :ok ->
        []

      {:error, reason} ->
        [
          %Finding{
            check: :unsearchable,
            subject: resource,
            message:
              Contract.message(resource, Lookup.action(resource), reason, """
              No list page or dropdown reaches #{inspect(resource)} yet, so \
              nothing has refused to compile over this — the moment one does, \
              it will.\
              """)
          }
        ]
    end
  end
end
