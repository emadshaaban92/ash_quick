# Demo data: three users, one per role, and a small catalog to work through.
#
#     mix run priv/repo/seeds.exs   # against an empty database
#     mix ash.reset                 # drop, recreate, migrate, re-seed
#
# It assumes an empty database — there is no find-or-create anywhere below.

alias Example.Accounts.User
alias Example.Catalog.{Brand, Category, PriceChange, Product}

# `:role` is a restricted field (see `Example.Checks.RoleIsAdminOnly`), and
# `AshQuick.FieldRestrictions.StripRestrictedFields` drops it from the changeset
# of any actor who is not an admin — including no actor at all, and including
# under `authorize?: false`, since stripping is defence in depth rather than
# authorization.
#
# So the first admin cannot be handed a role by anyone: it is created with no
# actor (a write nobody is behind, which records no audit entry) and then
# promotes itself, with a copy of its own record already carrying the role as
# the actor. Every other user below is created by it in one step.
seeded_admin =
  Ash.create!(User, %{name: "Ada Admin", email: "admin@example.test"}, authorize?: false)

admin =
  Ash.update!(seeded_admin, %{role: :admin},
    actor: %{seeded_admin | role: :admin},
    authorize?: false
  )

create_user = fn name, email, role ->
  Ash.create!(User, %{name: name, email: email, role: role}, actor: admin, authorize?: false)
end

editor = create_user.("Ed Editor", "editor@example.test", :editor)
_viewer = create_user.("Vera Viewer", "viewer@example.test", :viewer)

brands =
  for {code, name} <- [{"ACM", "Acme"}, {"GLB", "Globex"}, {"INI", "Initech"}] do
    Brand.create!(%{code: code, name: name}, actor: admin, authorize?: false)
  end

outdoors = Category.create!(%{code: "OUT", name: "Outdoors"}, actor: admin, authorize?: false)

categories =
  for {code, name} <- [{"TNT", "Tents"}, {"BAG", "Backpacks"}, {"LGT", "Lighting"}] do
    Category.create!(%{code: code, name: name, parent_id: outdoors.id},
      actor: admin,
      authorize?: false
    )
  end

products =
  for {sku, name, price, tags} <- [
        {"TNT-2P", "Two-person tent", Money.new(:USD, "249.00"), [:new]},
        {"TNT-4P", "Four-person tent", Money.new(:USD, "389.00"), []},
        {"BAG-40", "40L backpack", Money.new(:USD, "129.50"), [:sale]},
        {"BAG-70", "70L backpack", Money.new(:USD, "189.00"), [:staff_pick]},
        {"LGT-HL", "Headlamp", Money.new(:USD, "39.00"), [:clearance, :sale]}
      ] do
    Product.create!(
      %{
        sku: sku,
        name: name,
        description: "Seeded demo product. Edit me — the form is derived from the resource.",
        price: price,
        tags: tags,
        brand_id: Enum.random(brands).id,
        category_id: Enum.random(categories).id
      },
      actor: editor,
      authorize?: false
    )
  end

# One repricing, so `/price_changes` is not empty and a product carries a
# history its details page can show.
products
|> List.first()
|> Product.reprice!(Money.new(:USD, "229.00"), actor: editor, authorize?: false)

IO.puts("""

Seeded #{length(brands)} brands, #{length(categories) + 1} categories, \
#{length(products)} products and #{Ash.count!(PriceChange, authorize?: false)} price change(s).

Sign in at http://localhost:4000/login as any of:

  admin@example.test   (admin)  — everything, including impersonation
  editor@example.test  (editor) — the catalog, but no users or audit log
  viewer@example.test  (viewer) — the catalog, read-only
""")
