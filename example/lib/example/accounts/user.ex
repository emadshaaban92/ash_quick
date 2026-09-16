defmodule Example.Accounts.User do
  @moduledoc """
  The application's `:actor_resource`: who every page runs as.

  Being named in `config :ash_quick, actor_resource:` has three consequences
  worth seeing in one place.

    * Every other resource's `created_by` / `updated_by` relationships point
      here, so this is what a details page's "Created by X" header resolves
      through.
    * AshQuick generates an `:impersonate` action on it — one actor browsing as
      another — which is why the resource carries an authorizer and an audit
      trail. The impersonation writes nothing; the audit entry is the only
      record it ever happened, and `AshQuick.Impersonation.Verifier` refuses to
      compile the resource without both.
    * The `policy action(:impersonate)` below is the whole of who may stand in
      for whom. Nothing is generated for it, because only an application knows.

  Passwords are deliberately absent: `ExampleWeb.SessionController` signs a
  demo user in by picking them from a list. Authentication is the host's
  problem and not AshQuick's, and a real one would only obscure the seams this
  app exists to show.
  """

  use Ash.Resource,
    domain: Example.Accounts,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshQuick],
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "users"
    repo Example.Repo

    references do
      reference :store, on_delete: :nilify, on_update: :update
    end
  end

  resource do
    plural_name :users
  end

  actions do
    default_accept [:name, :email, :role, :locale, :store_id]
    defaults [:create, :read, :update, :destroy]

    read :index do
      argument :search, :string

      prepare Example.Accounts.Preparations.UsersSearch
      prepare build(sort: [name: :asc])

      pagination do
        keyset? true
        offset? true
        default_limit 20
        countable :by_default
      end
    end

    read :by_email do
      argument :email, :ci_string, allow_nil?: false
      get? true

      filter expr(email == ^arg(:email))
    end
  end

  policies do
    # Impersonation is an admin's, and only from `/browser_sessions`. Starting
    # one means minting the tab's token and pushing it to the browser, which
    # `AshQuick.LiveView.BrowserSessionsLive` does and a QuickView has no hook
    # to do: `:impersonate` takes no input, so a row action runs it inline and
    # the page moves on. Offered on a QuickView the button would write an audit
    # entry for an impersonation that never happened, and then nothing else —
    # so no QuickView surface is allowed to reach it.
    #
    # All three of them, not just the two a button is drawn on. `:impersonate`
    # takes no input, which is exactly what `ListUtils.resource_bulk_actions/3`
    # derives a bulk action from, so the list's bulk menu offers it over a
    # selection as well. That menu runs under `:ash_quick_list_bulk`, and
    # without the clause for it the audit entry this policy exists to prevent
    # is written once per selected row.
    #
    # Nobody stands in for themselves, which would be an entry for a session
    # that did not change hands.
    policy action(:impersonate) do
      forbid_if context_equals(:action_source, :ash_quick_list)
      forbid_if context_equals(:action_source, :ash_quick_details)
      forbid_if context_equals(:action_source, :ash_quick_list_bulk)
      forbid_if expr(id == ^actor(:id))
      authorize_if Example.Checks.ActorIsAdmin
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if Example.Checks.ActorIsAdmin
    end

    # Everyone signed in can read users: the details header of every other page
    # renders an actor's name through this action.
    policy action_type(:read) do
      authorize_if actor_present()
    end
  end

  ash_quick do
    display do
      label :name
    end

    activation do
      # Adds `:active` plus the `:activate` / `:deactivate` row actions. A
      # deactivated user is dimmed in the list and offered by no dropdown.
      enabled? true
    end

    bookkeeping do
      # Seeded and administered; there is no "who created this user" to record
      # that the audit trail does not already hold.
      created_by false
      updated_by false
    end

    field_restrictions do
      # Only an admin may hand out a role — and the field is hidden from
      # everyone else's form rather than merely refused on submit.
      restrict :role, Example.Checks.RoleIsAdminOnly, on: [:create, :update]
    end
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :email, :ci_string, allow_nil?: false, public?: true

    attribute :role, :atom,
      allow_nil?: false,
      public?: true,
      default: :viewer,
      constraints: [one_of: [:admin, :editor, :viewer]]

    # The language this person's pages render in. Unrestricted, unlike `:role`:
    # choosing your own language is not a privilege, and `/users` is an admin's
    # page only because everything else on it is.
    attribute :locale, :atom,
      allow_nil?: false,
      public?: true,
      default: :en,
      constraints: [one_of: [:en, :ar]]
  end

  relationships do
    # The tenant every action this person takes runs under. Nullable: platform
    # staff belong to no store and see every store's catalogue.
    belongs_to :store, Example.Catalog.Store do
      public? true
      allow_nil? true
    end
  end

  identities do
    identity :email, [:email]
  end
end
