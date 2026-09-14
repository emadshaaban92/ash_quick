defmodule Example.Repo do
  use AshPostgres.Repo, otp_app: :example

  @impl true
  def installed_extensions do
    # `ash-functions` is Ash's own; `AshMoney.AshPostgresExtension` installs the
    # composite type the `Money` column on `Example.Catalog.Product` is stored as.
    ["ash-functions", "citext", AshMoney.AshPostgresExtension]
  end

  @impl true
  def prefer_transaction?, do: false

  @impl true
  def min_pg_version do
    %Version{major: 16, minor: 0, patch: 0}
  end
end
