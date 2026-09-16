defmodule AshQuick.AuditTest do
  @moduledoc """
  The audit row is written inside the transaction of the write it describes.

  That is the claim only a transactional data layer can carry: a store that
  refuses the entry has to take the record back with it, and the caller is left
  with neither. The library's own suite runs on ETS, which has no transactions
  and so cannot show it.

  The `changes` column is the other thing that needs a real database here. It
  holds dumped values, so what a host reads back is JSONB with string keys
  rather than the atom-keyed maps an ETS store hands straight back — and a
  `Money` or an array of embedded resources only dumps the way a column would
  store it if a column is what it goes into. `from` also depends on
  AshPostgres returning records marked `:loaded`, which is the whole basis for
  telling "was nil" from "was never read".
  """
  # `async: false`: one test swaps the store through the application
  # environment, which every other test in the suite reads.
  use Example.DataCase, async: false

  require Ash.Query

  alias Example.Accounts.AuditLog
  alias Example.Catalog.Brand
  alias Example.Catalog.Product

  defp entries(record) do
    AuditLog
    |> Ash.Query.filter(resource_id == ^record.id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(authorize?: false)
  end

  describe "a store that refuses the batch" do
    setup do
      # The store is read per write rather than baked into the resource, so
      # swapping the application environment is enough to point it at one that
      # refuses.
      previous = Application.get_env(:ash_quick, :audit_resource)
      Application.put_env(:ash_quick, :audit_resource, AshQuick.AuditTest.RefusingStore)
      on_exit(fn -> Application.put_env(:ash_quick, :audit_resource, previous) end)

      :ok
    end

    test "fails the write, naming the resource and itself", %{admin: admin} do
      code = unique("B")

      # Ash wraps what a hook raises, which is what carries the reason out to
      # the caller — the entry could not be written, so neither could the brand.
      error =
        assert_raise Ash.Error.Unknown, fn ->
          Brand.create!(%{code: code, name: unique("Brand ")}, actor: admin, authorize?: false)
        end

      message = Exception.message(error)

      # Both ends of the write, so the report names what was being audited as
      # well as what would not take the entry.
      assert message =~ inspect(Brand)
      assert message =~ inspect(AshQuick.AuditTest.RefusingStore)

      # The store's own reason, rather than a MatchError on the bulk result.
      assert message =~ "audit store unreachable"

      # The brand was inserted and then rolled back with the refused entry, so
      # nothing is there — the property a non-transactional store cannot show.
      assert [] = Brand |> Ash.Query.filter(code == ^code) |> Ash.read!(authorize?: false)
    end
  end

  describe "changes" do
    test "an update records what changed and says nothing about what did not",
         %{admin: admin} do
      brand = brand(actor: admin)

      Brand.update!(brand, %{name: "Renamed", code: brand.code}, actor: admin, authorize?: false)

      assert [_created, entry] = entries(brand)

      # JSONB, so the keys come back as strings — the same map a host's
      # `/audit_logs` renders.
      assert entry.changes["name"] == %{"from" => brand.name, "to" => "Renamed"}

      # The code was submitted unchanged, as an edit form submits every field
      # the person did not touch, and says nothing here.
      refute Map.has_key?(entry.changes, "code")

      # The optimistic lock is an attribute the write changed like any other,
      # and the entry says so rather than pretending it did not.
      assert entry.changes["version"] == %{"from" => 1, "to" => 2}
    end

    test "a destroy records the record as it stood", %{admin: admin} do
      brand = brand(actor: admin)

      Brand.destroy!(brand, actor: admin, authorize?: false)

      assert [_created, entry] = entries(brand)

      # A destroy sets nothing, so the entry is every attribute rather than the
      # ones some action named.
      assert entry.changes["code"] == %{"from" => brand.code}
      assert entry.changes["name"] == %{"from" => brand.name}
      assert entry.changes["id"] == %{"from" => brand.id}
      assert entry.changes["created_at"]["from"]
    end

    test "an attribute the read did not select is unknown rather than nil", %{admin: admin} do
      brand = brand(actor: admin)

      [selected] =
        Brand
        |> Ash.Query.filter(id == ^brand.id)
        |> Ash.Query.select([:id, :code])
        |> Ash.read!(authorize?: false)

      assert %Ash.NotLoaded{} = selected.name

      Brand.update!(selected, %{name: "Renamed"}, actor: admin, authorize?: false)

      assert [_created, entry] = entries(brand)

      # `from: nil` would say the brand had been nameless, which is a different
      # claim from not knowing what it was called.
      assert entry.changes["name"] == %{"from_unknown" => true, "to" => "Renamed"}

      # And it is per key rather than per row: `version` is selected whatever
      # the query asked for, because the optimistic lock needs it, so its
      # previous value is known on the same write.
      assert entry.changes["version"] == %{"from" => 1, "to" => 2}
    end

    test "a money attribute and an embedded array are dumped on both sides",
         %{admin: admin} do
      product =
        product(
          price: Money.new(:USD, "10.00"),
          actor: admin
        )

      product =
        Product.update!(
          product,
          %{images: [%{alt: "front", featured: true}]},
          actor: admin,
          authorize?: false
        )

      Product.update!(
        product,
        %{
          price: Money.new(:USD, "12.50"),
          images: [%{alt: "back", featured: false}]
        },
        actor: admin,
        authorize?: false
      )

      assert [_created, _imaged, entry] = entries(product)

      # Dumped the way the column would hold them, applied identically to both
      # sides — not `inspect/1` of a `Money` struct, and not the struct itself.
      assert %{"from" => from_price, "to" => to_price} = entry.changes["price"]
      assert from_price == dumped(product.price)
      assert to_price == dumped(Money.new(:USD, "12.50"))

      assert %{"from" => [from_image], "to" => [to_image]} = entry.changes["images"]
      assert from_image["alt"] == "front"
      assert from_image["featured"] == true
      assert to_image["alt"] == "back"
      assert to_image["featured"] == false
    end
  end

  defp dumped(money) do
    attribute = Ash.Resource.Info.attribute(Product, :price)
    {:ok, dumped} = Ash.Type.dump_to_embedded(attribute.type, money, attribute.constraints)
    dumped
  end
end
