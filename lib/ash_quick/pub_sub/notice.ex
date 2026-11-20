defmodule AshQuick.PubSub.Notice do
  @moduledoc """
  What AshQuick broadcasts for a write: which record, of which resource, and
  whether it was a create, an update or a destroy. Nothing else.

  It is the payload of every `%Phoenix.Socket.Broadcast{}` on the topics in
  `AshQuick.Topics`. A page that hears one reads the record again itself,
  under its own reader's actor, tenant and policies, so what the page then
  shows is exactly what that reader may read. The broadcast carries no data
  that read would have to protect: not the record, the changeset, the
  arguments or the actor, any of which `Ash.Notifier.Notification` holds and
  every subscriber on the topic would otherwise receive.

  A publication a resource declares in its own `pub_sub` block is its own, and
  sends whatever that block says.
  """

  @enforce_keys [:resource, :id, :type]
  defstruct [:resource, :id, :type]

  @type t :: %__MODULE__{
          resource: Ash.Resource.t(),
          id: term(),
          type: :create | :update | :destroy
        }

  @doc false
  # The `transform` on each publication `AshQuick.PubSub.Transformer` adds.
  def from_notification(%Ash.Notifier.Notification{
        resource: resource,
        data: data,
        action: action
      }) do
    %__MODULE__{resource: resource, id: data.id, type: action.type}
  end
end
