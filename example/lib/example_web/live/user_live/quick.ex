defmodule ExampleWeb.UserLive.Quick do
  @moduledoc """
  The actor resource's own page.

  Worth reading for what is *not* here. `:impersonate` is generated onto the
  actor resource by the extension, and QuickView offers every update action the
  actor's policy says yes to — so this module would show an Impersonate button
  without mentioning one. It does not, because `Example.Accounts.User`'s policy
  forbids the action from both QuickView surfaces: an impersonation is started
  from `/browser_sessions`, which is the page that can mint the tab's token.

  What a QuickView offers is decided by the resource, which means a resource can
  take an action back off one too.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Accounts.User,
    list: [
      fields: [:name, :email, :role, :active],
      new_action_label: "Add User"
    ],
    details: [
      fields: [:name, :email, :role, :active, :created_at, :updated_at]
    ]
end
