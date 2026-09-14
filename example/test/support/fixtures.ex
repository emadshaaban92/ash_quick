defmodule Example.Fixtures do
  @moduledoc """
  The records a test starts from.

  Every unique-constrained value is generated rather than written out: two
  async tests taking the same literal both hold that index key until their
  sandbox transaction ends, so they serialize — and two shared keys taken in
  opposite orders deadlock.
  """

  alias Example.Accounts.User
  alias Example.Catalog.{Brand, Category, Product}

  @doc "One user per role, as `%{admin: ..., editor: ..., viewer: ...}`."
  def roles do
    admin = user(:admin)

    %{
      admin: admin,
      editor: user(:editor, actor: admin),
      viewer: user(:viewer, actor: admin)
    }
  end

  @doc """
  A user holding `role`.

  `:role` is a restricted field, so an actor who is not an admin has the value
  stripped from their changeset — including no actor at all. The first admin is
  therefore created role-less and promotes itself, which is the same bootstrap
  `priv/repo/seeds.exs` performs.
  """
  def user(role, opts \\ [])

  def user(:admin, opts) do
    seeded =
      Ash.create!(User, %{name: name(opts, "Admin"), email: email()}, authorize?: false)

    Ash.update!(seeded, %{role: :admin}, actor: %{seeded | role: :admin}, authorize?: false)
  end

  def user(role, opts) do
    actor = Keyword.get_lazy(opts, :actor, fn -> user(:admin) end)

    Ash.create!(User, %{name: name(opts, "User"), email: email(), role: role},
      actor: actor,
      authorize?: false
    )
  end

  def brand(opts \\ []) do
    Brand.create!(%{code: unique("B"), name: name(opts, "Brand")},
      actor: Keyword.get(opts, :actor),
      authorize?: false
    )
  end

  def category(opts \\ []) do
    Category.create!(
      %{
        code: unique("C"),
        name: name(opts, "Category"),
        parent_id: opts |> Keyword.get(:parent) |> id()
      },
      actor: Keyword.get(opts, :actor),
      authorize?: false
    )
  end

  def product(opts \\ []) do
    actor = Keyword.get(opts, :actor)

    Product.create!(
      %{
        sku: unique("SKU"),
        name: name(opts, "Product"),
        description: Keyword.get(opts, :description),
        price: Keyword.get(opts, :price, Money.new(:USD, "10.00")),
        tags: Keyword.get(opts, :tags, []),
        brand_id: opts |> Keyword.get_lazy(:brand, fn -> brand(actor: actor) end) |> id(),
        category_id: opts |> Keyword.get_lazy(:category, fn -> category(actor: actor) end) |> id()
      },
      actor: actor,
      authorize?: false
    )
  end

  @doc "A value nothing else in the suite will take."
  def unique(prefix), do: "#{prefix}#{System.unique_integer([:positive])}"

  defp email, do: Ash.CiString.new("#{unique("user")}@example.test")

  defp name(opts, default), do: Keyword.get(opts, :name) || unique("#{default} ")

  defp id(nil), do: nil
  defp id(%{id: id}), do: id
  defp id(id) when is_binary(id), do: id
end
