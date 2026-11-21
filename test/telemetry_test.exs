defmodule AshQuick.TelemetryTest do
  @moduledoc """
  The events `AshQuick.Telemetry` lists that the library can raise without a
  page: a missing translation, a storage call and an audit write. The route
  gate's refusal is asserted in `AshQuick.LiveView.RouteGateTest`, and the
  page events (loads, list reads, form submits, bulk runs, exports, prints)
  in the example app, which serves the pages.

  Not async: the translation and storage cases swap application config.
  """
  use ExUnit.Case, async: false

  alias AshQuick.Labels
  alias AshQuick.Storage
  alias AshQuick.Test.Actor
  alias AshQuick.Test.AuditLog
  alias AshQuick.Test.Tally

  defp attach(events) do
    ref = :telemetry_test.attach_event_handlers(self(), events)
    on_exit(fn -> :telemetry.detach(ref) end)
    ref
  end

  defp with_env(key, value, fun) do
    original = Application.get_env(:ash_quick, key)
    Application.put_env(:ash_quick, key, value)

    try do
      fun.()
    after
      Application.put_env(:ash_quick, key, original)
    end
  end

  describe "[:ash_quick, :translation, :missing]" do
    setup do
      %{ref: attach([[:ash_quick, :translation, :missing]])}
    end

    test "a message the host's backend lacks is reported with the locale it was asked in", %{
      ref: ref
    } do
      Gettext.put_locale(AshQuick.Test.Gettext, "ar")

      assert Gettext.dgettext(AshQuick.Gettext, "ash_quick", "Not in any catalogue") ==
               "Not in any catalogue"

      assert_received {[:ash_quick, :translation, :missing], ^ref, %{system_time: _},
                       %{
                         backend: AshQuick.Test.Gettext,
                         locale: "ar",
                         domain: "ash_quick",
                         msgctxt: nil,
                         msgid: "Not in any catalogue",
                         msgid_plural: nil
                       }}
    end

    test "a translated message is not reported", %{ref: ref} do
      Gettext.put_locale(AshQuick.Test.Gettext, "ar")

      assert Gettext.dgettext(AshQuick.Gettext, "ash_quick", "Cancel") == "إلغاء"

      refute_received {[:ash_quick, :translation, :missing], ^ref, _, _}
    end

    test "a plural message names both its forms", %{ref: ref} do
      Gettext.put_locale(AshQuick.Test.Gettext, "ar")

      Gettext.dngettext(AshQuick.Gettext, "ash_quick", "%{count} gap", "%{count} gaps", 3)

      assert_received {[:ash_quick, :translation, :missing], ^ref, _,
                       %{msgid: "%{count} gap", msgid_plural: "%{count} gaps", locale: "ar"}}
    end

    # With nothing to translate into, everything is drawn in English by
    # design, and nothing is missing.
    test "nothing is reported with no backend", %{ref: ref} do
      with_env(:gettext, nil, fn ->
        assert Gettext.dgettext(AshQuick.Gettext, "ash_quick", "Not in any catalogue") ==
                 "Not in any catalogue"
      end)

      refute_received {[:ash_quick, :translation, :missing], ^ref, _, _}
    end

    test "a label is reported under the context it was wanted in", %{ref: ref} do
      with_env(:gettext, AshQuick.Test.LabelGettext, fn ->
        Gettext.put_locale(AshQuick.Test.LabelGettext, "ar")

        assert Labels.translate("Price") == "السعر"
        refute_received {[:ash_quick, :translation, :missing], ^ref, _, _}

        assert Labels.translate("Not a label anywhere", "loan") == "Not a label anywhere"
      end)

      assert_received {[:ash_quick, :translation, :missing], ^ref, _,
                       %{
                         backend: AshQuick.Test.LabelGettext,
                         locale: "ar",
                         domain: "ash_quick",
                         msgctxt: "loan",
                         msgid: "Not a label anywhere"
                       }}
    end
  end

  describe "[:ash_quick, :storage, :call]" do
    defmodule FullStore do
      @moduledoc "A storage module refusing every file, and holding one state."
      def put_file(_key, _path, _opts), do: {:error, :full}
      def object_states(keys, _opts), do: Map.new(keys, &{&1, :processing})
    end

    defmodule BareStore do
      @moduledoc "A storage module implementing none of the lifecycle callbacks."
    end

    setup do
      %{
        ref:
          attach([
            [:ash_quick, :storage, :call, :start],
            [:ash_quick, :storage, :call, :stop]
          ])
      }
    end

    test "a call the storage answers is timed, with whether it failed", %{ref: ref} do
      with_env(:storage, FullStore, fn ->
        assert Storage.put_file("exports/1/list.csv", "/nonexistent") == {:error, :full}
        assert Storage.object_states(["a"]) == %{"a" => :processing}
      end)

      assert_received {[:ash_quick, :storage, :call, :start], ^ref, %{system_time: _},
                       %{operation: :put_file, storage: FullStore}}

      assert_received {[:ash_quick, :storage, :call, :stop], ^ref, %{duration: _},
                       %{operation: :put_file, storage: FullStore, result: :error}}

      assert_received {[:ash_quick, :storage, :call, :stop], ^ref, _,
                       %{operation: :object_states, storage: FullStore, result: :ok}}
    end

    test "a callback the storage does not implement is not called, and emits nothing", %{
      ref: ref
    } do
      with_env(:storage, BareStore, fn ->
        assert Storage.object_states(["a"]) == %{}
        assert Storage.object_arriving("a") == {:ok, "a"}
      end)

      refute_received {[:ash_quick, :storage, :call, _], ^ref, _, _}
    end
  end

  describe "[:ash_quick, :audit, :write]" do
    test "an audited write's rows are timed, with the store they went to" do
      ref = attach([[:ash_quick, :audit, :write, :stop]])

      actor = Actor |> Ash.Changeset.for_create(:create, %{name: "Auditor"}) |> Ash.create!()

      Tally
      |> Ash.Changeset.for_create(:create, %{name: "Gate", pin: "pin-1111-zq"}, actor: actor)
      |> Ash.create!()

      assert_received {[:ash_quick, :audit, :write, :stop], ^ref, %{duration: _},
                       %{resource: Tally, store: AuditLog, action_type: :create, rows: 1}}
    end
  end
end
