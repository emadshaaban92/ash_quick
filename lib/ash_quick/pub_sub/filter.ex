defmodule AshQuick.PubSub.Filter do
  @moduledoc false
  # Whether AshQuick's standard update publication goes out. Every update
  # publishes, except a *quiet* one that changes nothing.
  #
  # Quiet is opt-in, because whether an update changed what a page shows is
  # not something this side can know. An update that writes no attribute of
  # its record may still have done its real work in a hook: created or updated
  # other records that a calculation or aggregate on this one reads. Those
  # records' own broadcasts do not reach a page on this record, which listens
  # only on the records it holds, so silencing such an update would leave the
  # page showing stale data with no symptom. A broadcast too many is only a
  # wasted refetch.
  #
  # An update is quiet only when the resource lists it in `liveness quiet
  # [...]`, checked at compile time by `AshQuick.PubSub.Verifier`. No change
  # marks one quiet on its own, `AshQuick.Print` included: a print that also
  # numbers or records itself in a hook changes what a page shows.
  #
  # A quiet update still publishes when it is meaningful, on the one answer
  # `AshQuick.Bookkeeping.Meaningful` gives the lock and the stamps. Ash builds
  # the notification from the changeset as it was written, with every atomic
  # folded into its attributes. On the atomic path an accepted input is
  # written whether or not it differs from the row, and only the data layer
  # compared them, so a quiet atomic update that accepts any input publishes.
  #
  # Only the update publication AshQuick adds is filtered. Creates and
  # destroys always publish, and a publication the resource declares in its
  # own `pub_sub` block is the host's and is left as it is.

  alias AshQuick.Bookkeeping.Meaningful

  @doc false
  def publish?(%Ash.Notifier.Notification{
        resource: resource,
        changeset: %Ash.Changeset{} = changeset
      }) do
    changeset.action.name not in AshQuick.Info.quiet(resource) or
      Meaningful.meaningful?(changeset, List.wrap(AshQuick.Info.versioning_attribute(resource)))
  end

  def publish?(_notification), do: true
end
