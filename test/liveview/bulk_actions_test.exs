defmodule AshQuick.LiveView.BulkActionsTest do
  @moduledoc """
  What a page may name in `list: [bulk_actions: ...]`, and what it gets when it
  names nothing.

  A list is checked as the QuickView compiles, in `Options.new/3`, so a page
  that names something no selection can run does not compile: there is no
  page to drive, and these probe it directly. A function's list is only known
  once there is a socket to call it with, so it is checked when the menu is
  built, against the same rules.
  """
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.BulkActions
  alias AshQuick.LiveView.QuickView.Options
  alias AshQuick.Test.Bulk.Crate

  defp options!(bulk_actions) do
    Options.new(__MODULE__.SomeQuickView, Crate,
      resource: Crate,
      list: [bulk_actions: bulk_actions]
    )
  end

  defp refusal(bulk_actions) do
    Exception.message(assert_raise(ArgumentError, fn -> options!(bulk_actions) end))
  end

  defp socket(scope \\ nil) do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, scope: scope}}
  end

  describe "a list" do
    test "compiles with updates and destroys, with or without input, and custom items" do
      custom = %{title: "Export", link: "/crates/export"}
      options = options!([:rename, :close, :retire, :destroy, custom, nil])

      menu = BulkActions.menu(options, socket())

      # Exactly what was named, in its order; a falsy entry is skipped.
      assert Enum.map(menu, & &1.title) == ["Rename", "Close", "Retire", "Delete", "Export"]
      assert List.last(menu) == custom
    end

    test "naming an action the resource does not have does not compile" do
      message = refusal([:close, :shut])

      assert message =~ "SomeQuickView"
      assert message =~ ":shut"
      assert message =~ "has no action named :shut"
    end

    test "naming a read or a create does not compile" do
      for name <- [:index, :read, :create] do
        message = refusal([name])

        assert message =~ inspect(name)
        assert message =~ "only an update or a destroy acts on the selected rows"
      end
    end

    test "naming a private action does not compile" do
      message = refusal([:recount])

      assert message =~ ":recount"
      assert message =~ "is private"
    end

    test "naming an action that takes an upload does not compile" do
      message = refusal([:attach])

      assert message =~ ":attach takes uploads (:scan)"
      assert message =~ "An upload belongs to one record"
    end

    test "naming an action whose upload sits inside an embed does not compile" do
      message = refusal([:relabel])

      assert message =~ ":relabel takes uploads (:labels)"
    end

    test "an entry that is neither a name nor an item does not compile" do
      message = refusal(["close"])

      assert message =~ "neither an action name nor a custom item"
    end
  end

  describe "a function" do
    test "is checked when the menu is built, naming the page and the action" do
      options = options!(fn _socket -> [:close, :recount] end)

      message =
        Exception.message(
          assert_raise(ArgumentError, fn -> BulkActions.menu(options, socket()) end)
        )

      assert message =~ "SomeQuickView"
      assert message =~ ":recount"
      assert message =~ "is private"
    end

    test "that returns something other than a list is refused" do
      options = options!(fn _socket -> :close end)

      message =
        Exception.message(
          assert_raise(ArgumentError, fn -> BulkActions.menu(options, socket()) end)
        )

      assert message =~ "must return a list"
    end

    test "builds the menu it names" do
      options = options!(fn _socket -> [:retire] end)

      assert [%{title: "Retire"}] = BulkActions.menu(options, socket())
    end
  end

  describe "a page that names nothing" do
    test "gets every public update and destroy that takes no input" do
      options = Options.new(__MODULE__.SomeQuickView, Crate, resource: Crate)

      # `:rename`, `:attach` and `:relabel` take input; `:retire` is a destroy
      # that does, which used to be derived and run without its argument.
      assert options |> BulkActions.menu(socket()) |> Enum.map(& &1.title) == ["Close", "Delete"]
    end
  end

  describe "an event" do
    test "finds only an action the menu offered" do
      menu = BulkActions.menu(options!([:close, %{title: "Export", link: "/x"}]), socket())

      assert BulkActions.offered(menu, Crate, "close").name == :close
      assert BulkActions.offered(menu, Crate, "destroy") == nil
      assert BulkActions.offered(menu, Crate, "Export") == nil
      assert BulkActions.offered(menu, Crate, "recount") == nil
      assert BulkActions.offered(menu, Crate, nil) == nil
    end
  end
end
