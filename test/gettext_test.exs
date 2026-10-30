defmodule AshQuick.GettextTest do
  @moduledoc """
  `AshQuick.Gettext` holds no translations: each message is looked up in the
  host's backend, in its locale, and drawn in English when there is none.

  Not async: the backend is application config.
  """
  use ExUnit.Case, async: false

  @host AshQuick.Test.Gettext

  setup do
    Gettext.put_locale(@host, "ar")
    :ok
  end

  defp tabs(n),
    do: Gettext.dngettext(AshQuick.Gettext, "ash_quick", "%{count} tab", "%{count} tabs", n)

  test "reads a message in the host backend's locale" do
    assert Gettext.dgettext(AshQuick.Gettext, "ash_quick", "Cancel") == "إلغاء"
  end

  test "picks the host locale's plural form" do
    assert tabs(2) == "تبويبان"
    assert tabs(5) == "5 تبويبات"
  end

  # The host sets its own backend's locale, not AshQuick's, and not the
  # process-wide one.
  test "follows the host backend's locale, not its own" do
    Gettext.put_locale(AshQuick.Gettext, "en")
    assert tabs(2) == "تبويبان"
  end

  # What `lgettext/5` answers is what Gettext acts on, so a message the host
  # lacks too comes back as one the host lacks.
  test "answers as the host does when it has no translation either" do
    assert AshQuick.Gettext.lgettext("ar", "ash_quick", nil, "Not in any catalogue", %{}) ==
             {:default, "Not in any catalogue"}
  end

  test "refuses itself as the backend, which would forward to itself forever" do
    original = Application.get_env(:ash_quick, :gettext)
    Application.put_env(:ash_quick, :gettext, AshQuick.Gettext)
    on_exit(fn -> Application.put_env(:ash_quick, :gettext, original) end)

    assert_raise ArgumentError, ~r/not AshQuick.Gettext/, fn ->
      Gettext.dgettext(AshQuick.Gettext, "ash_quick", "Cancel")
    end
  end

  test "draws English, interpolated, with no backend" do
    original = Application.get_env(:ash_quick, :gettext)
    Application.delete_env(:ash_quick, :gettext)
    on_exit(fn -> Application.put_env(:ash_quick, :gettext, original) end)

    assert Gettext.dgettext(AshQuick.Gettext, "ash_quick", "Cancel") == "Cancel"
    assert tabs(1) == "1 tab"
    assert tabs(3) == "3 tabs"
  end
end
