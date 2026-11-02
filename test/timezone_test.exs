defmodule AshQuick.TimezoneTest do
  @moduledoc """
  The zone a reader reads timestamps in is the one put on their process, and
  only ever one the time zone database can shift into.
  """
  use ExUnit.Case, async: true

  alias AshQuick.Test.Zones
  alias AshQuick.Timezone

  test "is the configured zone until one is put" do
    assert Timezone.current() == AshQuick.Config.timezone()
  end

  test "is the zone put on the process" do
    assert Timezone.put("Etc/UTC") == "Etc/UTC"
    assert Timezone.current() == "Etc/UTC"
  end

  # Elixir's own database knows UTC alone, so a host with no other reads a
  # browser's zone as none rather than failing to shift into it.
  test "a zone the database does not know clears it" do
    Timezone.put("Etc/UTC")

    assert Timezone.put("Asia/Tokyo") == nil
    assert Timezone.current() == AshQuick.Config.timezone()

    assert Timezone.put(nil) == nil
    assert Timezone.current() == AshQuick.Config.timezone()
  end

  test "knows a zone the database can shift into, and nothing else" do
    assert Timezone.known?("Test/Plus3", Zones)
    refute Timezone.known?("Test/Nowhere", Zones)
    refute Timezone.known?(nil, Zones)
    refute Timezone.known?(3, Zones)
  end
end

defmodule AshQuick.TimezoneInputTest do
  @moduledoc """
  What a `datetime-local` input shows is what a QuickView reads the post in:
  the reader's zone. These run in UTC, the only zone Elixir's own database
  knows, so they pin the shape; the shift itself is pinned in
  `AshQuick.LiveView.LocalDatetimeTest` and the example app's
  `TimezoneScenarioTest`.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AshQuick.Test.LocalDatetime.Event

  test "input_value/1 shows an instant as a wall time, to the second it holds" do
    assert AshQuick.Timezone.input_value(~U[2026-10-22 07:00:00.123456Z]) == "2026-10-22T07:00"
    assert AshQuick.Timezone.input_value(~U[2026-10-22 07:00:05Z]) == "2026-10-22T07:00:05"
    assert AshQuick.Timezone.input_value("2026-10-22T07:00:00Z") == "2026-10-22T07:00"
    assert AshQuick.Timezone.input_value(nil) == nil
    assert AshQuick.Timezone.input_value("tomorrow") == "tomorrow"
  end

  test ".input draws a datetime-local field's instant through input_value/1, with step 1" do
    form =
      Event
      |> AshPhoenix.Form.for_create(:create, as: "form")
      |> AshPhoenix.Form.validate(%{"starts_at" => "2026-10-22T07:00:05.123456Z"})
      |> Phoenix.HTML.FormData.to_form([])

    html =
      render_component(&AshQuick.Components.input/1,
        field: form[:starts_at],
        type: "datetime-local"
      )

    assert html =~ ~s(value="2026-10-22T07:00:05")
    assert html =~ ~s(step="1")
  end

  test ".input keeps a step it is given" do
    form = Phoenix.HTML.FormData.to_form(AshPhoenix.Form.for_create(Event, :create), [])

    html =
      render_component(&AshQuick.Components.input/1,
        field: form[:starts_at],
        type: "datetime-local",
        step: "60"
      )

    assert html =~ ~s(step="60")
    refute html =~ ~s(step="1")
  end
end

defmodule AshQuick.LiveView.TimezoneTest do
  @moduledoc """
  The stage after a host's scope stage puts the scope's zone on the process,
  whoever filled it.
  """
  use ExUnit.Case, async: true

  defmodule ZonedScope do
    @moduledoc false
    use AshQuick.Scope, actor: :actor, timezone: :timezone
    defstruct [:actor, :timezone]
  end

  defp socket(scope),
    do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, scope: scope}}

  test "puts the scope's zone on the process" do
    AshQuick.Timezone.put(nil)

    assert {:cont, _socket} =
             AshQuick.LiveView.Timezone.on_mount(
               :default,
               %{},
               %{},
               socket(%ZonedScope{timezone: "Etc/UTC"})
             )

    assert Process.get({AshQuick.Timezone, :current}) == "Etc/UTC"
  end

  # Elixir's own database knows UTC alone: a zone stored on a user that it
  # cannot load reads as the configured one rather than raising.
  test "a scope naming no zone, or one the database does not know, leaves the configured one" do
    for scope <- [%ZonedScope{}, %ZonedScope{timezone: "Asia/Tokyo"}, nil] do
      AshQuick.LiveView.Timezone.on_mount(:default, %{}, %{}, socket(scope))
      assert AshQuick.Timezone.current() == AshQuick.Config.timezone()
    end
  end
end
