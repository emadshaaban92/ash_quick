defmodule Example.Accounts do
  @moduledoc """
  Who is acting, and what they did.

  `Example.Accounts.User` is the application's `:actor_resource` and
  `Example.Accounts.AuditLog` its `:audit_resource`; both are named in
  `config/config.exs`, which is where AshQuick looks for them.
  """
  use Ash.Domain

  resources do
    resource Example.Accounts.User
    resource Example.Accounts.AuditLog
  end
end
