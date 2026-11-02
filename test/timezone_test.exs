defmodule AshQuick.TimezoneTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.TimezoneTest.Meeting do
  @moduledoc "A timestamp to type into a form."
  use Ash.Resource,
    domain: AshQuick.TimezoneTest.Domain,
    data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  actions do
    defaults [:read, create: [:starts_at], update: [:starts_at]]
  end

  attributes do
    uuid_primary_key :id
    attribute :starts_at, :utc_datetime_usec, public?: true
  end
end

defmodule AshQuick.TimezoneTest.ZonedScope do
  @moduledoc false
  use AshQuick.Scope, actor: :actor, timezone: :timezone
  defstruct [:actor, :timezone]
end

defmodule AshQuick.TimezoneTest do
  @moduledoc """
  A timestamp reads in the reader's zone, the one their scope names, and a
  form's timestamp is typed in a zone picked beside it, which posts as the
  instant it means.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AshQuick.Config
  alias AshQuick.LiveView.FieldErrors
  alias AshQuick.TimezoneTest.{Meeting, ZonedScope}

  @stored ~U[2026-11-12 13:14:15.123456Z]

  describe "formatting" do
    test "shows a timestamp in the zone it is given" do
      assert Config.format_datetime(@stored, "Asia/Tokyo") =~ "10:14:15"
      assert Config.format_time(@stored, timezone: "Asia/Tokyo") =~ "10:14"
      assert Config.now_in_timezone("Asia/Tokyo").time_zone == "Asia/Tokyo"
    end

    test "shows one in the configured zone without one, or for one it cannot load" do
      for zone <- [nil, "Mars/Olympus"] do
        assert Config.format_datetime(@stored, zone) == Config.format_datetime(@stored)
        assert Config.format_datetime(@stored, zone) =~ "1:14:15"
      end
    end
  end

  describe "AshQuick.Scope.timezone/1" do
    test "is the scope's zone" do
      assert AshQuick.Scope.timezone(%ZonedScope{timezone: "Asia/Tokyo"}) == "Asia/Tokyo"
    end

    # A browser reports whatever it likes, and a shift into a zone the
    # database cannot load would fail the page.
    test "is the configured zone for none, or one the database does not know" do
      for scope <- [%ZonedScope{}, %ZonedScope{timezone: "Mars/Olympus"}, nil] do
        assert AshQuick.Scope.timezone(scope) == Config.timezone()
      end
    end
  end

  describe "zoned_datetime_input/1" do
    test "shows the held instant in the reader's zone, and posts it to the microsecond" do
      html = render_input(form(), timezone: "Asia/Tokyo")

      assert attribute(html, "[data-local]", "value") == "2026-11-12T22:14:15"
      assert attribute(html, "[data-local]", "name") == "form[starts_at__local]"
      assert attribute(html, "[data-local]", "step") == "1"
      assert attribute(html, "[data-instant]", "name") == "form[starts_at]"
      assert attribute(html, "[data-instant]", "value") == "2026-11-12T13:14:15.123456Z"
      assert attribute(html, "[data-zone]", "name") == "form[starts_at__zone]"
      assert attribute(html, "[data-zone] option[selected]", "value") == "Asia/Tokyo"
      assert attribute(html, "[phx-hook]", "phx-hook") =~ "ZonedDatetime"
    end

    test "keeps the zone a post picked, and shows the instant in it" do
      form =
        AshPhoenix.Form.validate(form(), %{
          "starts_at" => "2026-11-12T13:14:15Z",
          "starts_at__local" => "2026-11-12T08:14:15",
          "starts_at__zone" => "America/New_York"
        })

      html = render_input(form, timezone: "Asia/Tokyo")

      assert attribute(html, "[data-local]", "value") == "2026-11-12T08:14:15"
      assert attribute(html, "[data-zone] option[selected]", "value") == "America/New_York"
    end

    # Only a forged post holds a zone the picker never offered.
    test "shows the time in the reader's zone for a zone it does not offer" do
      form =
        AshPhoenix.Form.validate(form(), %{
          "starts_at" => "2026-11-12T13:14:15Z",
          "starts_at__local" => "2026-11-12T09:14:15",
          "starts_at__zone" => "Mars/Olympus"
        })

      html = render_input(form, timezone: "Asia/Tokyo")

      assert attribute(html, "[data-local]", "value") == "2026-11-12T22:14:15"
      assert attribute(html, "[data-zone] option[selected]", "value") == "Asia/Tokyo"
    end

    test "offers each zone by its offset and the places that keep it" do
      html = render_input(form(), timezone: "Asia/Tokyo")

      assert option_text(html, "Asia/Tokyo") == "(UTC+09:00) Tokyo, Seoul, Yakutsk"
      assert option_text(html, "Asia/Kathmandu") == "(UTC+05:45) Kathmandu"
    end

    test "starts empty for a form with no value" do
      form = Meeting |> AshPhoenix.Form.for_create(:create, as: "form") |> to_form()
      html = render_input(form, timezone: "Asia/Tokyo")

      assert attribute(html, "[data-local]", "value") in [nil, ""]
      assert attribute(html, "[data-instant]", "value") == ""
    end

    # What the action takes is the hidden input alone: the time and the zone
    # beside it are left out of its input.
    test "saves what the hidden input posts, whatever posts beside it" do
      {:ok, meeting} =
        Meeting
        |> AshPhoenix.Form.for_create(:create, as: "form")
        |> AshPhoenix.Form.submit(
          params: %{
            "starts_at" => "2026-11-13T08:30:00Z",
            "starts_at__local" => "2026-11-13T09:30",
            "starts_at__zone" => "Europe/Berlin"
          }
        )

      assert meeting.starts_at == ~U[2026-11-13 08:30:00.000000Z]
    end
  end

  test "editing the time or the zone marks the field used" do
    for input <- ["starts_at__local", "starts_at__zone"] do
      assert FieldErrors.mark_used(%{}, ["form", input]) == %{"_used_starts_at" => "true"}
    end
  end

  defp form do
    meeting = Ash.create!(Meeting, %{starts_at: @stored})
    meeting |> AshPhoenix.Form.for_update(:update, as: "form") |> to_form()
  end

  defp to_form(form), do: Phoenix.HTML.FormData.to_form(form, [])

  defp render_input(%AshPhoenix.Form{} = form, opts), do: render_input(to_form(form), opts)

  defp render_input(form, opts) do
    render_component(
      &AshQuick.Components.zoned_datetime_input/1,
      [field: form[:starts_at], label: "Starts at"] ++ opts
    )
  end

  defp option_text(html, zone) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-zone] option[value="#{zone}"]))
    |> LazyHTML.text()
    |> String.trim()
  end

  defp attribute(html, selector, name) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
    |> List.first()
  end
end
