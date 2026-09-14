defmodule ExampleWeb.UserLive.Quick do
  @moduledoc """
  The actor resource's own page — where an admin starts an impersonation.

  `:impersonate` is not listed anywhere here. It is generated onto the actor
  resource by the extension, and QuickView offers every update action the
  actor's policy says yes to, so what puts the button on a details page (and
  keeps it off the list) is `Example.Accounts.User`'s policy and nothing on
  this module.
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
