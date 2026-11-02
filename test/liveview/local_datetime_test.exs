defmodule AshQuick.LiveView.LocalDatetimeTest do
  @moduledoc """
  A timestamp is typed into a filter or a form in the zone the page shows it
  in and held as the UTC instant, so "after 10:00" means 10:00 where the
  reader reads the list rather than 10:00 UTC.
  """
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.LocalDatetime
  alias AshQuick.Test.LocalDatetime.Event
  alias AshQuick.Test.Zones

  describe "to_utc/3" do
    test "reads a browser's value, which has no seconds, in the list's zone" do
      assert LocalDatetime.to_utc("2026-10-22T10:00", "Test/Plus3", Zones) ==
               "2026-10-22T07:00:00Z"

      assert LocalDatetime.to_utc("2026-10-22T10:00:30", "Test/Plus3", Zones) ==
               "2026-10-22T07:00:30Z"
    end

    test "is the value as typed in UTC" do
      assert LocalDatetime.to_utc("2026-10-22T10:00", "Etc/UTC") == "2026-10-22T10:00:00Z"
    end

    test "reads a skipped wall time as the first instant after the gap" do
      assert LocalDatetime.to_utc("2026-03-29T02:30", "Test/Shifting", Zones) ==
               "2026-03-29T01:00:00Z"
    end

    test "reads a repeated wall time as the earlier instant" do
      assert LocalDatetime.to_utc("2026-10-25T02:30", "Test/Shifting", Zones) ==
               "2026-10-25T00:30:00Z"
    end

    # A value that names its offset is an instant already, so a value carried
    # back through a second validate is not shifted again.
    test "keeps a value that names its offset as that instant" do
      assert LocalDatetime.to_utc("2026-10-22T07:00:00Z", "Test/Plus3", Zones) ==
               "2026-10-22T07:00:00Z"

      assert LocalDatetime.to_utc("2026-10-22T10:00:00+03:00", "Test/Shifting", Zones) ==
               "2026-10-22T07:00:00Z"
    end

    test "leaves what will not parse as it was typed, for the read to refuse" do
      for value <- ["", "tomorrow", "2026-13-01T10:00"] do
        assert LocalDatetime.to_utc(value, "Test/Plus3", Zones) == value
      end

      assert LocalDatetime.to_utc(nil, "Test/Plus3", Zones) == nil

      assert LocalDatetime.to_utc("2026-10-22T10:00", "Test/Nowhere", Zones) ==
               "2026-10-22T10:00"
    end
  end

  describe "to_local/3" do
    test "shows a held instant in the list's zone, to the minute" do
      assert LocalDatetime.to_local("2026-10-22T07:00:00Z", "Test/Plus3", Zones) ==
               "2026-10-22T10:00"
    end

    test "keeps seconds the instant has" do
      assert LocalDatetime.to_local("2026-10-22T07:00:30Z", "Test/Plus3", Zones) ==
               "2026-10-22T10:00:30"
    end

    test "reads a value with no zone, from a URL written before, as UTC" do
      assert LocalDatetime.to_local("2026-10-22T07:00", "Test/Plus3", Zones) ==
               "2026-10-22T10:00"
    end

    test "is the inverse of to_utc/3" do
      for typed <- ["2026-01-05T09:15", "2026-07-05T23:59", "2026-10-22T10:00:30"] do
        held = LocalDatetime.to_utc(typed, "Test/Shifting", Zones)
        assert LocalDatetime.to_local(held, "Test/Shifting", Zones) == typed
      end
    end

    test "shows a held DateTime in the zone" do
      assert LocalDatetime.to_local(~U[2026-10-22 07:00:00.000000Z], "Test/Plus3", Zones) ==
               "2026-10-22T10:00"

      assert LocalDatetime.to_local(~U[2026-10-22 07:00:30Z], "Test/Plus3", Zones) ==
               "2026-10-22T10:00:30"
    end

    test "shows an instant the zone cannot hold in UTC" do
      assert LocalDatetime.to_local(~U[2026-10-22 07:00:00Z], "Test/Nowhere", Zones) ==
               "2026-10-22T07:00"

      assert LocalDatetime.to_local("2026-10-22T07:00:00Z", "Test/Nowhere", Zones) ==
               "2026-10-22T07:00"
    end

    test "shows what will not parse as it was typed" do
      assert LocalDatetime.to_local("tomorrow", "Test/Plus3", Zones) == "tomorrow"
      assert LocalDatetime.to_local(nil, "Test/Plus3", Zones) == nil
    end
  end

  describe "day_range/3" do
    test "is the day from its first moment in the zone up to the next day's" do
      assert LocalDatetime.day_range("2026-10-22", "Test/Plus3", Zones) ==
               {:ok, "2026-10-21T21:00:00Z", "2026-10-22T21:00:00Z"}
    end

    # The day the clocks spring forward is an hour short, and the day they fall
    # back an hour long.
    test "follows the zone's shifts, so a day need not be 24 hours" do
      assert LocalDatetime.day_range("2026-03-29", "Test/Shifting", Zones) ==
               {:ok, "2026-03-28T23:00:00Z", "2026-03-29T22:00:00Z"}

      assert LocalDatetime.day_range("2026-10-25", "Test/Shifting", Zones) ==
               {:ok, "2026-10-24T22:00:00Z", "2026-10-25T23:00:00Z"}
    end

    test "is no range for a value that is no date" do
      assert LocalDatetime.day_range("2026-13-45", "Test/Plus3", Zones) == :error
      assert LocalDatetime.day_range(nil, "Test/Plus3", Zones) == :error
    end
  end

  describe "form_params_to_utc/4" do
    defp create_form, do: AshPhoenix.Form.for_create(Event, :create, as: "form")

    test "reads the instants a form's action takes in the zone, and nothing else" do
      params = %{
        "starts_at" => "2026-10-22T10:00",
        "remind_at" => "2026-10-22T09:30",
        "on_day" => "2026-10-22",
        "title" => "2026-10-22T10:00"
      }

      assert LocalDatetime.form_params_to_utc(params, create_form(), "Test/Plus3", Zones) == %{
               "starts_at" => "2026-10-22T07:00:00Z",
               "remind_at" => "2026-10-22T06:30:00Z",
               "on_day" => "2026-10-22",
               "title" => "2026-10-22T10:00"
             }
    end

    test "reads a drawn sub-form's instants in the zone too" do
      form =
        create_form()
        |> AshPhoenix.Form.add_form("form[stamps]")
        |> AshPhoenix.Form.add_form("form[stamps]")

      params = %{
        "starts_at" => "",
        "stamps" => %{
          "0" => %{"at" => "2026-10-22T10:00", "label" => "a"},
          "1" => %{"at" => "2026-10-22T11:00", "label" => "b"}
        }
      }

      assert %{
               "starts_at" => "",
               "stamps" => %{
                 "0" => %{"at" => "2026-10-22T07:00:00Z", "label" => "a"},
                 "1" => %{"at" => "2026-10-22T08:00:00Z", "label" => "b"}
               }
             } = LocalDatetime.form_params_to_utc(params, form, "Test/Plus3", Zones)
    end

    # The input shows the second, so the record's microseconds would be lost
    # on every save, and Ash would record the field as changed.
    test "keeps the record's own instant when posted back as the input showed it" do
      record =
        Ash.create!(Event, %{starts_at: ~U[2026-10-22 07:00:05.123456Z]}, action: :create)

      form = AshPhoenix.Form.for_update(record, :update, as: "form")

      assert LocalDatetime.form_params_to_utc(
               %{"starts_at" => "2026-10-22T10:00:05"},
               form,
               "Test/Plus3",
               Zones
             ) == %{"starts_at" => "2026-10-22T07:00:05.123456Z"}

      assert LocalDatetime.form_params_to_utc(
               %{"starts_at" => "2026-10-22T10:00:30", "remind_at" => "2026-10-22T10:00:05"},
               form,
               "Test/Plus3",
               Zones
             ) == %{"starts_at" => "2026-10-22T07:00:30Z", "remind_at" => "2026-10-22T07:00:05Z"}
    end

    test "changes nothing on a second pass" do
      params = %{"starts_at" => "2026-10-22T10:00"}
      once = LocalDatetime.form_params_to_utc(params, create_form(), "Test/Plus3", Zones)
      assert LocalDatetime.form_params_to_utc(once, create_form(), "Test/Plus3", Zones) == once
    end
  end
end
