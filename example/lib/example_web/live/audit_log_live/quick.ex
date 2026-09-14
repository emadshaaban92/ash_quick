defmodule ExampleWeb.AuditLogLive.Quick do
  @moduledoc """
  The trail every audited write lands in, routed `only: [:index, :show]`.

  `:real_actor_name` is what an impersonated write reads as: the actor column
  holds whoever the tab was standing in for, and this one holds the person who
  was actually at the keyboard.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Accounts.AuditLog,
    load: [actor: [:name], real_actor: [:name]],
    list: [
      fields: [
        :resource_name,
        :resource_id,
        :action_type,
        :action_name,
        {[actor: :name], label: "Actor"},
        {[real_actor: :name], label: "Real actor"},
        :ip,
        :created_at
      ]
    ],
    details: [
      fields: [
        :resource_name,
        :resource_id,
        :action_type,
        :action_name,
        :attributes,
        :arguments,
        :context,
        {[actor: :name], label: "Actor"},
        {[real_actor: :name], label: "Real actor"},
        :ip,
        :created_at
      ]
    ]
end
