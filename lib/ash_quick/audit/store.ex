defmodule AshQuick.Audit.Store do
  @moduledoc """
  Records a batch of writes in the resource's audit store.

  The store is an Ash resource in the host app — `mix igniter.install ash_quick`
  generates it — named per resource under `audit do store ... end` or app-wide
  as `:audit_resource`. It is the system of record, so it is written here rather
  than through a sink the host implements: `real_actor_id` and `ip` come off
  `AshQuick.Scope`'s provenance, and a host reproducing that from memory is
  exactly the columns-silently-nil failure the contract exists to prevent.

  ## The row

  Every store carries these, and `AshQuick.Audit.Verifier` refuses to compile a
  resource whose store is missing one:

  #{Enum.map_join(AshQuick.Audit.Row.fields(), "\n", &"  * `#{&1}`")}

  A host adding columns of its own fills them from the store resource's own
  `:create` action, which is the whole row — nothing here reads them.

  ## Failure

  The write happens in `after_batch`, inside the action's transaction, so a
  store that refuses the batch fails the write that produced it and both go
  back. That is deliberate and is the trade the store makes: an audited write
  that cannot be recorded did not happen, which puts the audit table on the
  critical path of every write. Keep the store dumb — no policies to evaluate,
  no validations to trip, one bulk insert.
  """

  alias AshQuick.Audit.Declaration
  alias AshQuick.Audit.Row

  @doc """
  Writes a row per `{changeset, record}` pair, and raises naming the resource
  and the store if the batch does not land.
  """
  def write([{changeset, _record} | _] = changes, actor) do
    resource = changeset.resource
    store = Declaration.store(resource)

    changes
    |> Enum.map(&Row.build(&1, actor))
    |> Ash.bulk_create(store, :create,
      actor: actor,
      authorize?: false,
      return_errors?: true,
      stop_on_error?: true
    )
    |> case do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{errors: errors} ->
        raise AshQuick.Audit.WriteError, resource: resource, store: store, errors: errors
    end
  end
end
