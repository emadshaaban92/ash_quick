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
  end

  resource do
    plural_name :users
  end

  actions do
    default_accept [:name, :email, :role]
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
    # Impersonation is an admin's, and only from a details page: the list's
    # generic row action cannot finish the job (only a details page mints the
    # tab's token), so offering it there would leave an audit entry for an
    # impersonation that never happened.
    policy action(:impersonate) do
      forbid_if context_equals(:action_source, :ash_quick_list)
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
  end

  identities do
    identity :email, [:email]
  end
end
