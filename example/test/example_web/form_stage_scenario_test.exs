defmodule ExampleWeb.FormStageScenarioTest do
  @moduledoc """
  A QuickView form tells an action's change what it is doing:
  `AshQuick.form_build_stage/0` once as it opens,
  `AshQuick.form_validate_stage/0` on every `phx-change` or upload after that,
  `AshQuick.form_submit_stage/0` when it is submitted, and nothing at all to
  any other caller. The run keeps its `action_source`,
  `AshQuick.form_source/0`, beside it.

  `Example.Test.FormStages` seeds its note only when the form is built, shows
  the stage it last saw in its `stage_seen` input, and records the stage its
  change ran under and the stage and source its run carried.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.FormStages
  alias Example.Test.FormStages.RecordStage

  @modal "#ash-quick-action-modal"
  @note "#{@modal} input[name='form[note]']"
  @label "#{@modal} input[name='form[label]']"
  @stage_seen "#{@modal} input[name='form[stage_seen]']"
  @bulk "a[phx-click*='bulk_action']"
  @jpeg File.read!("priv/static/favicon.ico")

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  describe "the form" do
    test "is built as it opens, and shows what the build seeded", %{conn: conn} do
      # The note is an argument, the label an accepted attribute: both are
      # read off the built changeset into the form's params.
      conn
      |> visit("/test/form_stages/create")
      |> assert_has("#{@note}[value='#{RecordStage.seeded()}']")
      |> assert_has("#{@label}[value='#{RecordStage.seeded_label()}']")
    end

    test "of an update is built as it opens, and seeds the note", %{conn: conn} do
      record = direct()

      conn
      |> visit("/test/form_stages/#{record.id}/renote")
      |> assert_has("#{@note}[value='#{RecordStage.seeded()}']")
    end

    test "is validated on a change, which leaves a cleared note cleared", %{conn: conn} do
      conn
      |> visit("/test/form_stages/create")
      |> fill_in(@note, "Note", with: "")
      |> assert_has("#{@stage_seen}[value='#{AshQuick.form_validate_stage()}']")
      |> refute_has("#{@note}[value='#{RecordStage.seeded()}']")
    end

    test "keeps the seed through an upload before any change", %{conn: conn} do
      conn
      |> visit("/test/form_stages/create")
      |> unwrap(fn view ->
        view
        |> file_input("#{@modal} form", "form[image]_upload", [
          %{name: "photo.jpg", content: @jpeg, type: "image/jpeg", size: byte_size(@jpeg)}
        ])
        |> render_upload("photo.jpg")
      end)
      # The upload validated the form, with nothing posted for either seed.
      |> assert_has("#{@stage_seen}[value='#{AshQuick.form_validate_stage()}']")
      |> assert_has("#{@note}[value='#{RecordStage.seeded()}']")
      |> assert_has("#{@label}[value='#{RecordStage.seeded_label()}']")
    end

    test "is validated after a submit it refused, which seeds nothing", %{conn: conn} do
      conn
      |> visit("/test/form_stages/create")
      # No code: the run refuses it, and the form stays open.
      |> click_button("#{@modal} button", "Save")
      |> assert_has(@modal, text: "is required")
      |> fill_in(@note, "Note", with: "")
      |> assert_has("#{@stage_seen}[value='#{AshQuick.form_validate_stage()}']")
      |> refute_has("#{@note}[value='#{RecordStage.seeded()}']")
    end
  end

  describe "a submit" do
    test "saves under the submit stage, from the form source", %{conn: conn} do
      code = unique("F")

      conn
      |> visit("/test/form_stages/create")
      |> fill_in("#{@modal} input", "Code", with: code)
      |> click_button("#{@modal} button", "Save")
      |> refute_has("#flash-error")

      assert [record] = by_code(code)
      assert record.note == RecordStage.seeded()
      assert record.label == RecordStage.seeded_label()
      assert record.built_stage == AshQuick.form_submit_stage()
      assert record.run_stage == AshQuick.form_submit_stage()
      assert record.run_source == AshQuick.form_source()
    end

    test "seeds nothing: a note cleared on the form is saved empty", %{conn: conn} do
      code = unique("F")

      conn
      |> visit("/test/form_stages/create")
      |> fill_in(@note, "Note", with: "")
      |> fill_in("#{@modal} input", "Code", with: code)
      |> click_button("#{@modal} button", "Save")
      |> refute_has("#flash-error")

      assert [record] = by_code(code)
      assert record.note == nil
      assert record.built_stage == AshQuick.form_submit_stage()
    end

    test "of a bulk action runs under the submit stage, from the form source", %{conn: conn} do
      first = direct()
      second = direct()

      conn
      |> visit("/test/form_stages")
      |> tick_rows([first.id, second.id])
      |> click_link(@bulk, "Renote")
      |> fill_in(@note, "Note", with: "Renoted")
      |> click_button("#{@modal} button", "Save")
      |> refute_has("#flash-error")

      for record <- [first, second] do
        record = Ash.reload!(record)
        assert record.note == "Renoted"
        assert record.built_stage == AshQuick.form_submit_stage()
        assert record.run_stage == AshQuick.form_submit_stage()
        assert record.run_source == AshQuick.form_source()
      end
    end
  end

  test "a caller outside any form sees no stage and no source" do
    record = direct()

    assert record.note == nil
    assert record.built_stage == nil
    assert record.run_stage == nil
    assert record.run_source == nil
  end

  defp direct, do: Ash.create!(FormStages, %{code: unique("F")})

  defp by_code(code), do: FormStages |> Ash.read!() |> Enum.filter(&(&1.code == code))
end
