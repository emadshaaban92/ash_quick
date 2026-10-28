defmodule AshQuick.LiveView.Components.SensitiveLabelTest do
  @moduledoc """
  A label or a hint whose field is `sensitive?`, wherever a page names a
  person or a record by it.

  `AshQuick.Info.display_value/1` and `display_hint_value/1` redact such a
  field themselves, so nothing that reads them — a related record's link, the
  details header's writers, the impersonation banner, the Live Users
  register, a dropdown, a page title — can show it. The register's presence
  needs a running endpoint, which this package has none of; it reads the same
  two functions, which are pinned here, and the example app drives the
  register itself.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias AshQuick.LiveView.Components.FieldValue
  alias AshQuick.LiveView.Components.ImpersonationBanner
  alias AshQuick.Test.Linked.{Locker, Maker, Part, Vault}
  alias AshQuick.Test.Scopes.DerivedScope

  defp vault, do: %Vault{id: Ash.UUID.generate(), pin: "4321", code: "V-1"}
  defp locker, do: %Locker{id: Ash.UUID.generate(), name: "Locker 9", combination: "0815"}

  describe "the text a page shows" do
    test "masks a sensitive label, and leaves a plain one" do
      assert AshQuick.Info.display_value(vault()) == "********"
      assert AshQuick.Info.display_value(%Maker{name: "Acme"}) == "Acme"
    end

    test "masks a sensitive hint, and leaves a plain one" do
      assert AshQuick.Info.display_hint_value(locker()) == "********"
      assert AshQuick.Info.display_hint_value(vault()) == "V-1"
    end

    # One mark whatever the value, so not even its length shows.
    test "with a mark of the same length whatever the value" do
      assert AshQuick.Info.display_value(%Vault{pin: "1"}) ==
               AshQuick.Info.display_value(%Vault{pin: "123456789012"})
    end

    test "is nothing for what has no label to read" do
      assert AshQuick.Info.display_value(%Vault{
               pin: %Ash.ForbiddenField{field: :pin, type: :attribute}
             }) == nil

      assert AshQuick.Info.display_value(nil) == nil
      assert AshQuick.Info.display_hint_value(nil) == nil
    end
  end

  describe "the impersonation banner" do
    defp banner(actor) do
      render_component(&ImpersonationBanner.impersonation_banner/1,
        scope: %DerivedScope{user: actor, behind: %Maker{id: Ash.UUID.generate(), name: "Admin"}}
      )
    end

    test "masks a sensitive label" do
      html = banner(vault())

      assert html =~ "You&#39;re impersonating ******** (V-1)"
      refute html =~ "4321"
    end

    test "masks a sensitive hint" do
      html = banner(locker())

      assert html =~ "You&#39;re impersonating Locker 9 (********)"
      refute html =~ "0815"
    end
  end

  test "a related record's link masks a sensitive hint in its tooltip and name" do
    locker = locker()

    html =
      render_component(&FieldValue.field_value/1,
        value: %Part{id: Ash.UUID.generate(), locker: locker},
        path: :locker,
        linker: &"/linked/#{&1.id}"
      )

    assert html =~ ~s(title="********")
    assert html =~ ~s[aria-label="Locker 9 (********)"]
    refute html =~ "0815"
  end
end
