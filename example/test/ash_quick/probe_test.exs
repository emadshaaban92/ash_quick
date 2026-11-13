defmodule AshQuick.ProbeTest do
  @moduledoc """
  What an action's validations see when a QuickView probes the action rather
  than runs it.

  Ash builds a probe's changeset to check its policies, and building it runs
  the action's changes and validations. The bulk menu probes each derived
  update and destroy with no record, so Ash builds that changeset over an
  empty struct. `AshQuick.probe?/1` lets a validation that reads the record
  tell such a changeset from a run.
  """
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.BulkActions
  alias Example.Test.ProbedDestroys

  setup do
    %{scope: Example.Scope.new(actor: nil)}
  end

  defp record(code) do
    ProbedDestroys
    |> Ash.Changeset.for_create(:create, %{code: code})
    |> Ash.create!(authorize?: false)
  end

  defp seen(name) do
    receive do
      {:validated, ^name, probe?, id} -> {probe?, id}
    after
      0 -> :not_run
    end
  end

  test "the bulk menu's record-less probe is a probe, built over no record", %{scope: scope} do
    menu = BulkActions.derived(ProbedDestroys, scope)

    assert seen(:unguarded) == {{true, true}, nil}
    assert seen(:guarded) == {{true, true}, nil}

    # The probe never validates, so a validation that refuses the empty record
    # does not take the action off the menu.
    assert :destroy in Enum.map(menu, & &1.ash_quick_action)
  end

  test "a validation run in a before_action hook is not run by a probe", %{scope: scope} do
    menu = BulkActions.derived(ProbedDestroys, scope)

    assert :discard in Enum.map(menu, & &1.ash_quick_action)
    assert seen(:deferred) == :not_run
  end

  test "a row's probe is a probe, built over the row", %{scope: scope} do
    row = record("row-probe")

    assert AshQuick.can?({row, :destroy}, scope, :ash_quick_list)
    assert seen(:unguarded) == {{true, true}, row.id}
  end

  test "a run is not a probe, from a QuickView form or anywhere else" do
    for context <- [%{action_source: AshQuick.form_source()}, %{}] do
      row = record("run")

      row
      |> Ash.Changeset.for_destroy(:destroy, %{}, context: context)
      |> Ash.destroy!(authorize?: false)

      assert seen(:unguarded) == {{false, false}, row.id}
      assert seen(:guarded) == {{false, false}, row.id}
    end
  end

  test "a query is a probe only when a surface's probe built it" do
    query = Ash.Query.new(ProbedDestroys)

    refute AshQuick.probe?(query)
    assert AshQuick.probe?(Ash.Query.set_context(query, %{action_source: :ash_quick_details}))
    refute AshQuick.probe?(Ash.Query.set_context(query, %{action_source: :ash_quick_form}))
  end
end
