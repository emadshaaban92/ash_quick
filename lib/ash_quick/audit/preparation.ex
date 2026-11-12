defmodule AshQuick.Audit.Preparation do
  @moduledoc """
  Records who read a record, for the read actions a resource lists in
  `read_actions`:

      ash_quick do
        audit do
          read_actions [:open]
        end
      end

  Every read through a listed action writes one row per record it returns into
  the resource's `AshQuick.Audit.Store` — the same store, the same row and the
  same write as a create, update or destroy. The row names the returned record
  in `resource_id`, says `action_type: :read` and the action's name, and keeps
  the query's arguments in `arguments`, with a `sensitive?` one redacted as on
  a write (and recorded when named in `record_sensitive`). `attributes` is
  `%{}`, and so is `changes` on a store that has the column. `context`,
  `actor_id`, `real_actor_id`, `ip` and `tenant` are filled exactly as for a
  write, so an impersonated read names both people.

  That covers every way the action is run: `Ash.read/2`, `Ash.get/3` and a code
  interface on a `get?` action, a paginated read (a row for each record on the
  page it returned), `Ash.stream!/3` (a row for each record in each batch), and
  the action loading a relationship of another resource.

  ## What gets no row

    * **A read through an action that is not listed.** Lists and searches are
      the usual reason: a page of twenty rows is not twenty reads anyone needs
      on record, so only the actions that open a record should be listed. A
      relationship or aggregate loaded alongside a listed read records nothing
      unless the action it is read through is listed too.
    * **A read that returns nothing.** Only returned records get rows, so a
      record that was not found, or that the read's policies filtered out, is
      not recorded — and neither is a refused read.
    * **A permission check.** `Ash.can?/3` and `AshQuick.can?` on a listed
      action, with a record or without, never run the read, so they record
      nothing. Ash builds the query for them, and with it this preparation,
      but the hook that writes the rows only runs when the read does.
    * **Loading onto records already in hand.** `Ash.load/3` through a listed
      action reads nothing new — the records were recorded by the read that
      returned them — and Ash runs no `after_action` hook for it.
    * **A resource that does not audit.** One that turns auditing off, the
      audit store itself and an embedded resource record no reads, and
      `AshQuick.Audit.Verifier` refuses `read_actions` on them.

  Nothing is deduplicated: a record opened twice is recorded twice. Whether
  to keep fewer rows is the host's decision. A QuickView details page whose
  `details: [default_action: ...]` is a listed action reads its record when the
  page first renders, again when it connects, and again whenever a change
  elsewhere makes it read the record afresh, so one visit is several rows.

  ## Failure

  A read does not run in a transaction, so there is nothing to roll back. The
  rows are written in the last of the query's `after_action` hooks instead,
  after any other hook has had its say on which records are returned and
  before they are handed back, and a store that refuses them fails the read with
  an `AshQuick.Audit.WriteError`: the read returns nothing. A read that cannot
  be recorded does not happen, as a write that cannot be recorded does not.
  """

  use Ash.Resource.Preparation

  require Ash.Tracer

  alias AshQuick.Audit.Change
  alias AshQuick.Audit.Store

  # The writer has to be the last `after_action` hook to run, because another
  # one can still drop records or fail the read, and a row for a record the
  # read did not return says it was read when it was not. Ash prepends hooks by
  # default and appends them under `read_action_after_action_hooks_in_order?`,
  # so where a preparation adds one decides nothing. A `before_action` hook
  # runs once every preparation has, so the writer is appended to the end of
  # the list from there, and Ash runs the list in order.
  @impl true
  def prepare(query, opts, context) do
    if query.action.name in Keyword.fetch!(opts, :actions) do
      Ash.Query.before_action(query, fn query ->
        %{query | after_action: query.after_action ++ [writer(context.actor)]}
      end)
    else
      query
    end
  end

  defp writer(actor) do
    fn query, records ->
      record(query, records, actor)
      {:ok, records}
    end
  end

  defp record(_query, [], _actor), do: :ok

  defp record(query, records, actor) do
    Ash.Tracer.span :custom, "Audit Log", query.context[:private][:tracer] do
      query = redact(query)

      records
      |> Enum.map(&{query, &1, %{}})
      |> Store.write(actor)
    end
  end

  defp redact(query) do
    {_attributes, arguments} = Change.to_redact(query)
    %{query | arguments: Change.redact(query.arguments, arguments)}
  end
end
