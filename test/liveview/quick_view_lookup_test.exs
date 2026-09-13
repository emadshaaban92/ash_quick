defmodule AshQuick.LiveView.QuickViewLookupTest do
  @moduledoc """
  The half of the lookup contract `AshQuick.Lookup.Verifier` deliberately
  cannot enforce: that an action a QuickView actually reaches through *exists*.

  Absence cannot be judged at the resource, because whether a resource needs a
  lookup action is not a fact about the resource — it is a fact about what
  points at it. A line item or a join row carries the extension and has no
  `:index`, and is correct as it stands: nothing lists it and no form renders a
  dropdown onto it.

  So the demand is made here, while the QuickView compiles, where what points
  at what is known. Two readers are held to it — the action this page lists and
  exports through, and every resource a dropdown on one of its forms would
  search. The second is the one that fails silently otherwise: the destination
  is a resource nobody was editing, the crash surfaces on someone else's page,
  and it surfaces the first time a user opens the dropdown rather than at
  compile time.

  `Options.new/3` runs in the QuickView's module body, so a failure is a
  compile error and there is no page to drive. These probe it directly: a
  QuickView that failed to compile serves no request.

  One kind of dropdown escapes that check entirely, and the last block covers
  it. `BelongsToInput` and `HasManyInput` are plain live components, so a
  template outside a QuickView — a hand-written page, a layout's tenant
  switcher — can point one at any destination it likes. Nothing at compile time
  walks a `.heex` to find them, so they are held to the same contract at the
  open, through `Utils.lookup_action!/1`.
  """
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.QuickView.Options
  alias AshQuick.LiveView.Utils

  alias AshQuick.Test.Lookup.{
    OtherName,
    PointsAtNoExtension,
    PointsAtOtherName,
    Searchable,
    Unlisted
  }

  defp options!(resource, opts \\ []) do
    Options.new(__MODULE__.SomeQuickView, resource, Keyword.put(opts, :resource, resource))
  end

  test "a dropdown onto a resource with no lookup action does not compile" do
    # `Searchable` is itself perfectly listable — the failure is entirely about
    # the resource on the other end of a relationship its create form renders,
    # which is what makes this the case no test at the resource could state.
    message = Exception.message(assert_raise(ArgumentError, fn -> options!(Searchable) end))

    assert message =~ "renders a dropdown onto"
    assert message =~ "Unlisted"
    assert message =~ "defines no :index action"

    # The message has to name the fix at the destination, since that is the file
    # the reader has to open and it is not the one they were editing.
    assert message =~ "read :index do"
    assert message =~ "argument :search, :string"
  end

  test "the resource a page lists through is held to the same contract" do
    # The list and export path, which resolves its action from the same
    # declaration and passes the same argument.
    message = Exception.message(assert_raise(ArgumentError, fn -> options!(Unlisted) end))

    assert message =~ "lists"
    assert message =~ "Unlisted"
    assert message =~ "defines no :index action"
  end

  test "a per-view default_action override is what gets checked" do
    # `list: [default_action: ...]` is the narrower question of what this one
    # page lists, so the override — not the resource's declaration — is what
    # has to satisfy the contract.
    message =
      Exception.message(
        assert_raise(ArgumentError, fn ->
          options!(Searchable, list: [default_action: :create])
        end)
      )

    assert message =~ "is a create action, not a read"
  end

  test "a dropdown destination is resolved through its own declaration, not :index" do
    # The destination satisfies the contract under `:search_them` and has no
    # `:index` at all, so this compiles only because the check resolves what
    # the destination declared. A dropdown still spelling the convention would
    # refuse the page over an action the destination was never going to need.
    #
    # Stated positively because the negative cannot reach here: a destination
    # declaring an action it does not have fails its own resource verifier
    # (`AshQuick.LookupVerifierTest`), so no such resource gets as far as being
    # pointed at.
    assert %Options{} = options!(PointsAtOtherName)
  end

  test "a field rendered by a widget is not asked for a lookup action" do
    # `Searchable`'s `:unlisted` belongs_to is the dropdown the first test in
    # this file refuses the page over. Configure a widget for it and there is
    # no dropdown to search from: `FormView.field_input/1` matches the widget
    # clause before the relationship ones, so the destination is never read and
    # demanding a lookup action of it would refuse a page over a search that
    # cannot happen.
    assert %Options{} =
             options!(Searchable, form: [widgets: %{unlisted: fn assigns -> assigns end}])
  end

  test "a dropdown destination carrying no extension is named with what points at it" do
    # Resolving the destination's action is itself what raises for a resource
    # without the extension, so the extension is checked first — otherwise the
    # failure knows only the destination, and the dropdown that led there is
    # the half the reader cannot guess from the destination's own file.
    message =
      Exception.message(assert_raise(ArgumentError, fn -> options!(PointsAtNoExtension) end))

    assert message =~ "renders a dropdown onto"
    assert message =~ "NoExtension"
    assert message =~ "does not carry the AshQuick extension"

    # The fix is the extension, not a read action — the generic prose would
    # send the reader to write an action nothing would consult. Refuted on the
    # prose rather than on `read :index do`, which this branch would not print
    # either way: with no extension there is no declaration to name, so the
    # generic clause would render `read nil do` and the refutation would pass
    # while the wrong message shipped.
    assert message =~ "extensions: [AshQuick"
    refute message =~ "A lookup action has to exist"
  end

  test "the list action defaults to the resource's declaration, not to :index" do
    # The literal `:index` used to live at this call site. Reading it from the
    # resource is what lets a resource whose searchable read is named something
    # else be listed without every QuickView over it restating the name.
    assert options!(OtherName).list_default_action == :search_them
  end

  describe "dropdowns placed outside a QuickView" do
    test "are held to the contract at the open, naming the relationship" do
      # No QuickView is involved, which is the point: this is the dropdown a
      # bespoke LiveView or a layout renders by hand. The check cannot happen
      # at compile time, so it happens on the read the component was about to
      # build — the same failure, carrying the relationship and the fix.
      relationship = Ash.Resource.Info.relationship(Searchable, :unlisted)

      message =
        Exception.message(
          assert_raise(ArgumentError, fn -> Utils.lookup_action!(relationship) end)
        )

      # Which dropdown, not merely which destination — the destination's own
      # file says nothing about what pointed at it. Pinned whole, since the
      # relationship is named by interpolation and a stray `inspect/1` renders
      # it as `Searchable.:unlisted`, which no file spells.
      assert message =~ "A dropdown onto AshQuick.Test.Lookup.Searchable.unlisted searches"
      assert message =~ "defines no :index action"
    end

    test "resolve the destination's declaration when it satisfies the contract" do
      # The happy path is what every dropdown in the app takes, and it returns
      # the destination's declared action rather than a literal `:index`.
      relationship = Ash.Resource.Info.relationship(PointsAtOtherName, :target)

      assert Utils.lookup_action!(relationship) == :search_them
    end
  end
end
