defmodule AshQuick.Audit.WriteError do
  @moduledoc """
  An audited write whose entry the store refused.

  Raised from `AshQuick.Audit.Store` inside the action's transaction, so the
  write that produced the entry goes back with it. That is the store's contract
  rather than an accident of how the insert is matched: a record that exists
  with no row saying who created it is the failure auditing is for, and it is
  discovered later, by whoever needed the log.

  What reaches here is a store that cannot take the row at all — a column the
  library writes that the resource does not have, a foreign key to an actor
  that is gone, a validation on a resource that was supposed to stay dumb, the
  database being down. None of those are per-record conditions a caller can
  correct, which is why this raises rather than returning an error for the
  action to collect.
  """

  defexception [:resource, :store, :errors]

  @impl true
  def exception(opts) do
    %__MODULE__{
      resource: opts[:resource],
      store: opts[:store],
      errors: List.wrap(opts[:errors])
    }
  end

  @impl true
  def message(%__MODULE__{resource: resource, store: store, errors: errors}) do
    """
    #{inspect(resource)}: the audit entry could not be written to #{inspect(store)}.

    The write it records is rolled back with it — an audited write that cannot \
    be recorded did not happen.

    The store reported:

    #{describe(errors)}

    An audit store is written on the critical path of every write to \
    #{inspect(resource)}, so keep it dumb: no policies, no validations, and \
    every column AshQuick fills present on the resource.
    """
  end

  defp describe([]), do: "(nothing — the batch failed without reporting an error)"

  defp describe(errors), do: Enum.map_join(errors, "\n", &error_message/1)

  defp error_message(%{__exception__: true} = error), do: Exception.message(error)
  defp error_message(error), do: inspect(error)
end
