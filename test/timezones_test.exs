defmodule AshQuick.TimezonesTest.Domain do
  @moduledoc false
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.TimezonesTest.Meeting do
  @moduledoc "A timestamp to type into a form."
  use Ash.Resource,
    domain: AshQuick.TimezonesTest.Domain,
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

defmodule AshQuick.TimezonesTest.ZonedScope do
  @moduledoc false
  use AshQuick.Scope, actor: :actor, timezone: :timezone
  defstruct [:actor, :timezone]
end

defmodule AshQuick.TimezonesTest do
  @moduledoc """
  `config :ash_quick, timezones:` says which zones a reader may read and type
  timestamps in: by default the configured zone alone, a list of them, or
  every zone the server knows, offered one per clock the world keeps.

  Not async: each test sets the application's configuration.
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias AshQuick.{Config, Timezones}
  alias AshQuick.TimezonesTest.{Meeting, ZonedScope}

  @stored ~U[2026-11-12 13:14:15.123456Z]

  setup do
    previous = Application.get_all_env(:ash_quick)
    Application.delete_env(:ash_quick, :timezones)
    Application.delete_env(:ash_quick, :timezone)

    on_exit(fn ->
      for key <- [:timezones, :timezone] do
        case Keyword.fetch(previous, key) do
          {:ok, value} -> Application.put_env(:ash_quick, key, value)
          :error -> Application.delete_env(:ash_quick, key)
        end
      end
    end)
  end

  describe "by default" do
    setup do
      Application.put_env(:ash_quick, :timezone, "Asia/Tokyo")
    end

    test "allows the configured zone alone" do
      assert Config.timezones() == ["Asia/Tokyo"]
      assert Timezones.allowed?("Asia/Tokyo")
      refute Timezones.allowed?("Europe/Berlin")
    end

    # A page never shows a zone its forms will not take.
    test "reads a scope's other zone as the configured one" do
      assert AshQuick.Scope.timezone(%ZonedScope{timezone: "Europe/Berlin"}) == "Asia/Tokyo"
    end

    test "draws no picker, and still says which zone the time is in" do
      html = render_input(timezone: "Asia/Tokyo")

      assert attribute(html, "select", "name") == nil
      assert attribute(html, "input[data-zone]", "type") == "hidden"
      assert attribute(html, "input[data-zone]", "value") == "Asia/Tokyo"
      assert attribute(html, "[data-local]", "value") == "2026-11-12T22:14:15"
    end
  end

  describe "a list" do
    setup do
      Application.put_env(:ash_quick, :timezone, "Europe/London")
      Application.put_env(:ash_quick, :timezones, ["Europe/London", "Asia/Tokyo"])
    end

    test "allows the zones it names" do
      assert Timezones.allowed?("Asia/Tokyo")
      refute Timezones.allowed?("Europe/Berlin")
      assert AshQuick.Scope.timezone(%ZonedScope{timezone: "Asia/Tokyo"}) == "Asia/Tokyo"
      assert AshQuick.Scope.timezone(%ZonedScope{timezone: "Europe/Berlin"}) == "Europe/London"
    end

    test "is offered in its own order" do
      assert Enum.map(Timezones.options("Asia/Tokyo"), &elem(&1, 1)) ==
               ["Europe/London", "Asia/Tokyo"]

      html = render_input(timezone: "Asia/Tokyo")
      assert attribute(html, "select option[selected]", "value") == "Asia/Tokyo"
    end

    test "must hold the configured zone" do
      Application.put_env(:ash_quick, :timezones, ["Asia/Tokyo"])
      assert_raise ArgumentError, ~r/must hold the default zone/, &Config.timezones/0
    end

    test "or be :all" do
      Application.put_env(:ash_quick, :timezones, "Asia/Tokyo")
      assert_raise ArgumentError, ~r/takes a list of zones or :all/, &Config.timezones/0
    end
  end

  describe ":all" do
    setup do
      Application.put_env(:ash_quick, :timezones, :all)
    end

    test "allows any zone the database knows" do
      assert Timezones.allowed?("Europe/Paris")
      refute Timezones.allowed?("Mars/Olympus")
    end

    test "offers one zone per clock, by its offset now" do
      zones = Enum.map(Timezones.options("Etc/UTC"), &elem(&1, 1))

      assert "Europe/Berlin" in zones
      refute "Europe/Paris" in zones
      assert length(zones) < 80

      offsets = Enum.map(zones, &offset_now/1)
      assert offsets == Enum.sort(offsets)
    end

    test "offers the reader's own zone too" do
      assert {"(UTC" <> _, "Europe/Paris"} =
               Enum.find(Timezones.options("Europe/Paris"), &(elem(&1, 1) == "Europe/Paris"))
    end
  end

  test "every clock it offers is a zone the database knows" do
    Application.put_env(:ash_quick, :timezones, :all)

    for {_label, zone} <- Timezones.options("Etc/UTC") do
      assert Timezones.known?(zone), "#{zone} is not a zone the database knows"
    end
  end

  defp offset_now(zone) do
    now = DateTime.shift_zone!(DateTime.utc_now(), zone)
    now.utc_offset + now.std_offset
  end

  defp render_input(opts) do
    form =
      Meeting
      |> Ash.create!(%{starts_at: @stored})
      |> AshPhoenix.Form.for_update(:update, as: "form")
      |> Phoenix.HTML.FormData.to_form([])

    render_component(
      &AshQuick.Components.zoned_datetime_input/1,
      [field: form[:starts_at], label: "Starts at"] ++ opts
    )
  end

  defp attribute(html, selector, name) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(name)
    |> List.first()
  end
end
