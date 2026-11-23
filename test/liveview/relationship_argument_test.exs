defmodule AshQuick.LiveView.RelationshipArgumentTest do
  @moduledoc """
  Which relationship a list argument edits, which is what a form renders a
  dropdown for, prefills on update and loads the record with. It is read off
  the action's `manage_relationship` changes, so the argument's name is the
  resource's to choose; the `<relationship>_ids` name is only the fallback.
  """
  use ExUnit.Case, async: true

  alias Ash.Resource.Actions.Argument
  alias Ash.Resource.Relationships.ManyToMany
  alias AshQuick.LiveView.QuickView.Options
  alias AshQuick.LiveView.Utils
  alias AshQuick.Test.RelationshipArgs.Post

  defp relationship(action, argument) do
    arg = Enum.find(Ash.Resource.Info.action(Post, action).arguments, &(&1.name == argument))
    Utils.argument_to_relationship(arg, Post, action)
  end

  defp created(action, argument) do
    arg = Enum.find(Ash.Resource.Info.action(Post, action).arguments, &(&1.name == argument))
    Utils.created_values(arg, relationship(action, argument), action)
  end

  defp key(action, argument) do
    arg = Enum.find(Ash.Resource.Info.action(Post, action).arguments, &(&1.name == argument))
    Utils.list_key(arg, relationship(action, argument), action)
  end

  test "an argument named for its relationship edits it" do
    assert %ManyToMany{name: :tags} = relationship(:create, :tags)
  end

  test "an argument named for nothing edits the relationship its change names" do
    assert %ManyToMany{name: :labels} = relationship(:relabel, :picked)
  end

  test "a global manage_relationship change counts" do
    assert %ManyToMany{name: :labels} = relationship(:everywhere, :everywhere)
  end

  test "the action's own change wins over a global one for the same argument" do
    assert %ManyToMany{name: :tags} = relationship(:overridden, :overridden)
  end

  test "with no change, an _ids argument still edits the relationship it names" do
    assert %ManyToMany{name: :tags} = relationship(:legacy, :tags_ids)
  end

  test "an _ids argument naming no relationship stays an argument" do
    assert %Argument{name: :legacy_ids} = relationship(:legacy, :legacy_ids)
  end

  describe "a list of text" do
    test "edits the relationship whose change looks it up by value_is_key" do
      for action <- [:named_create, :named_create_with, :named_code, :named_strict] do
        assert %ManyToMany{name: :tags} = relationship(action, :names)
      end

      assert key(:named_create, :names) == :name
      assert key(:named_code, :names) == :code
    end

    test "names nothing when its change never looks a name up, or names no key" do
      assert %Argument{name: :names} = relationship(:named_unlooked, :names)
      assert %Argument{name: :names} = relationship(:named_unkeyed, :names)
    end

    test "adds what matches nothing when the change creates it" do
      assert created(:named_create, :names) == %{
               action: :create,
               match: :exact,
               read_action: :read
             }

      assert created(:named_create_with, :names) == %{
               action: :tagged,
               match: :exact,
               read_action: :read
             }
    end

    test "matches in any case on a ci_string key" do
      assert created(:named_code, :names) == %{
               action: :create,
               match: :any_case,
               read_action: :read
             }
    end

    test "adds nothing when the change creates nothing" do
      assert created(:named_strict, :names) == nil
    end

    test "adds nothing through a create that does not take the key" do
      assert created(:named_unfillable, :names) == nil
    end
  end

  test "an id list adds nothing, though its change creates what it misses" do
    assert %ManyToMany{name: :tags} = relationship(:ids_create, :ids)
    assert key(:ids_create, :ids) == :id
    assert created(:ids_create, :ids) == nil
  end

  test "a page renders a dropdown for an argument not named _ids" do
    widget = fn assigns -> assigns end

    # `Tag` has no lookup action, so the page refuses to compile only if it
    # found a dropdown onto `Tag`. Every other id-list argument renders through
    # a widget, which leaves `:create`'s `:tags` as the only dropdown there is.
    message =
      Exception.message(
        assert_raise(ArgumentError, fn ->
          Options.new(__MODULE__.SomeQuickView, Post,
            resource: Post,
            form: [
              widgets:
                Map.new(
                  [:picked, :everywhere, :overridden, :tags_ids, :names, :ids],
                  &{&1, widget}
                )
            ]
          )
        end)
      )

    assert message =~ "renders a dropdown onto"
    assert message =~ "RelationshipArgs.Tag"
  end
end
