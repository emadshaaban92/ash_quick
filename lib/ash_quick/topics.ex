defmodule AshQuick.Topics do
  @moduledoc """
  The PubSub topics AshQuick publishes and subscribes on.

  Both sides of liveness go through here. `AshQuick.PubSub.Transformer` builds a
  resource's publications from `prefix/1` and the same tenant rules, and
  `AshQuick.LiveView.Liveness` builds a QuickView's subscriptions from
  `collection/2` and `record/3` — so a page cannot listen on a topic the
  resource does not publish. A topic spelled out on either side could disagree
  with the other, and a subscription to a topic nobody publishes has no
  symptom: the page simply never updates.

  The prefix is declared in the resource's `ash_quick.liveness` block and
  defaults to its `short_name`.

  ## Tenants

  A multitenant resource publishes inside its tenant: `"product:tenant:<t>"`
  and `"product:tenant:<t>:<id>"`, so a page hears only the writes of the
  tenant it reads in. `<t>` is what the resource compares a reader's tenant
  against: the tenant attribute's value under `strategy :attribute`, and the
  tenant itself (after `Ash.ToTenant`) under `strategy :context`. An attribute
  resource publishes on its record's attribute as written, so a write made
  without a tenant still reaches the tenant whose record it changed. A record
  moved to another tenant is announced in the new one only: a page in the old
  one holding it is not told, and shows it until it next reads.

  A resource that some reader may read across tenants also publishes every
  write on the bare topics: one that is `global? true`, or has a read action
  whose `multitenancy` is `:allow_global`, `:bypass` or `:bypass_all`. A page
  listens there when it reads across tenants: with no tenant, or through a
  `:bypass` or `:bypass_all` action (which also listens there for the related
  records it loads, where their resource publishes there). A resource nobody
  may read across tenants publishes nothing on the bare topics.

  A tenant whose value contains the delimiter (`":"`) cannot be
  told apart from another tenant's record topic, so it is given no topics: its
  writes are not published inside it and its pages are not live.

  A resource with no `multitenancy` publishes on the bare topics only, and the
  reader's tenant plays no part in them.

  What goes out on these topics is an `AshQuick.PubSub.Notice`, never the
  record: see there.
  """

  @tenant_segment "tenant"

  @doc """
  Whether this resource publishes at all.

  False for a resource that does not carry the `AshQuick` extension, and for one
  that carries it with `enabled? false` — a resource wanting read-only fields
  without liveness, or one whose write volume makes broadcasting a bad trade.
  """
  def enabled?(resource) do
    AshQuick in Spark.extensions(resource) and
      Spark.Dsl.Extension.get_opt(resource, [:ash_quick, :liveness], :enabled?, true)
  end

  @doc """
  The resource's topic prefix: `"product"`.

  The first segment of every topic the resource publishes, tenant or not. It
  names the resource on the wire, which is why it has to be unique across
  resources. Takes a resource or, while it compiles, its DSL state.
  """
  def prefix(resource) do
    Spark.Dsl.Extension.get_opt(resource, [:ash_quick, :liveness], :prefix, nil) ||
      to_string(Ash.Resource.Info.short_name(resource))
  end

  @doc """
  The resource-wide topic a reader in `tenant` listens on: `"product"`, or
  `"product:tenant:<t>"` on a multitenant resource read in a tenant.

  Published for every create, update and destroy in that tenant, except a
  quiet update that changes nothing, so a subscriber hears about the whole
  collection it can read — including records it has never seen. A list
  listens here, which is how it knows to offer a Reload.

  `tenant` is the tenant the reader reads in, as its scope holds it; `nil`
  for a reader with none. `nil` comes back for a tenant whose value contains
  the delimiter, which names no topic.
  """
  def collection(resource, tenant) do
    case tenant_value(resource, tenant) do
      nil -> prefix(resource)
      :unnamed -> nil
      value -> Enum.join([prefix(resource), @tenant_segment, value], delimiter())
    end
  end

  @doc """
  One record's topic for a reader in `tenant`: `"product:<id>"`, or
  `"product:tenant:<t>:<id>"` on a multitenant resource read in a tenant.

  Published alongside `collection/2` for the same changes. A details page, and
  a list for the related records its rows show, listen on these and hear
  nothing about the rest.
  """
  def record(resource, id, tenant) do
    case collection(resource, tenant) do
      nil -> nil
      collection -> "#{collection}#{delimiter()}#{id}"
    end
  end

  @doc """
  The delimiter between a topic's segments.

  Matches `Ash.Notifier.PubSub`'s default, since that is what publishes.
  """
  def delimiter, do: ":"

  @doc false
  # The `Ash.Notifier.PubSub` template part that renders the tenant segment of
  # a multitenant resource's topics, or `nil` for one without multitenancy.
  # Takes a resource or, while it compiles, its DSL state.
  def tenant_template(resource) do
    case Ash.Resource.Info.multitenancy_strategy(resource) do
      :attribute -> Ash.Resource.Info.multitenancy_attribute(resource)
      :context -> :_tenant
      nil -> nil
    end
  end

  @doc false
  def tenant_segment, do: @tenant_segment

  @crossing [:allow_global, :bypass, :bypass_all]

  @doc false
  # Whether some reader may read this resource across tenants, and so listens
  # on the bare topics. Takes a resource or, while it compiles, its DSL state.
  def publishes_bare?(resource) do
    is_nil(Ash.Resource.Info.multitenancy_strategy(resource)) or
      Ash.Resource.Info.multitenancy_global?(resource) or
      Enum.any?(Ash.Resource.Info.actions(resource), fn action ->
        action.type == :read and action.multitenancy in @crossing
      end)
  end

  @doc false
  # Whether a notification's tenant segment names a topic: false only for a
  # value containing the delimiter. A `nil` one is skipped by the template.
  def nameable?(%Ash.Notifier.Notification{resource: resource} = notification) do
    value =
      case tenant_template(resource) do
        nil -> nil
        :_tenant -> notification.changeset && notification.changeset.to_tenant
        attribute -> Map.get(notification.data, attribute)
      end

    is_nil(value) or not String.contains?(to_string(value), delimiter())
  end

  # The same value the publishing side renders: what Ash compares an attribute
  # tenant against (`parse_attribute` over `Ash.ToTenant`), or the tenant a
  # context resource's changeset carries (`Ash.ToTenant`). The template joins
  # it with `to_string/1`, and so does this.
  defp tenant_value(_resource, nil), do: nil

  defp tenant_value(resource, tenant) do
    case Ash.Resource.Info.multitenancy_strategy(resource) do
      nil ->
        nil

      strategy ->
        to_tenant = Ash.ToTenant.to_tenant(tenant, resource)

        value =
          case strategy do
            :attribute ->
              {m, f, a} = Ash.Resource.Info.multitenancy_parse_attribute(resource)
              apply(m, f, [to_tenant | a])

            :context ->
              to_tenant
          end

        cond do
          is_nil(value) -> nil
          String.contains?(to_string(value), delimiter()) -> :unnamed
          true -> to_string(value)
        end
    end
  end
end
