defmodule AshQuick.ActivationTest do
  @moduledoc """
  The `:active` attribute activation adds is NOT NULL.

  A record is either active or not. A `nil` one would be a third state nothing
  in AshQuick means: the dropdowns withhold it as if inactive, while the row
  actions offer it both `:activate` and `:deactivate`. So the attribute refuses
  `nil` on every write, and a new record still starts out active.
  """
  use ExUnit.Case, async: true

  alias AshQuick.Test.Activation.Activated
  alias AshQuick.Test.Activation.OwnActive

  describe "the attribute the extension adds" do
    test "a new record is active when nothing says otherwise" do
      record = Ash.create!(Activated, %{name: "a"})

      assert record.active == true
    end

    test "a create refuses `active: nil`" do
      assert {:error, %Ash.Error.Invalid{} = error} =
               Ash.create(Activated, %{name: "a", active: nil})

      assert Enum.any?(error.errors, &match?(%Ash.Error.Changes.Required{field: :active}, &1))
    end

    test "an update refuses `active: nil`" do
      record = Ash.create!(Activated, %{name: "a"})

      assert {:error, %Ash.Error.Invalid{} = error} =
               record
               |> Ash.Changeset.for_update(:update, %{active: nil})
               |> Ash.update()

      assert Enum.any?(error.errors, &match?(%Ash.Error.Changes.Required{field: :active}, &1))
    end

    test "`:deactivate` and `:activate` still write it" do
      record = Ash.create!(Activated, %{name: "a"})

      record = record |> Ash.Changeset.for_update(:deactivate) |> Ash.update!()
      assert record.active == false

      record = record |> Ash.Changeset.for_update(:activate) |> Ash.update!()
      assert record.active == true
    end
  end

  describe "a resource that defines `:active` itself" do
    test "keeps its own `allow_nil?`" do
      assert %{allow_nil?: true} = Ash.Resource.Info.attribute(OwnActive, :active)

      assert %OwnActive{active: nil} = Ash.create!(OwnActive, %{name: "a", active: nil})
    end
  end
end
