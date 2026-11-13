defmodule ExampleWeb.ImpersonationExpiryTest do
  @moduledoc """
  A tab that is still connected when its token runs out stops impersonating
  there and then, not at its next mount.

  It shortens `:impersonation_max_age` for the whole node, which every other
  impersonating test's token would feel, so it runs alone.
  """
  use ExampleWeb.FeatureCase, async: false

  setup do
    previous = Application.fetch_env(:ash_quick, :impersonation_max_age)
    Application.put_env(:ash_quick, :impersonation_max_age, 1)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:ash_quick, :impersonation_max_age, value)
        :error -> Application.delete_env(:ash_quick, :impersonation_max_age)
      end
    end)
  end

  test "a connected tab is sent back to its page as itself once the token expires", ctx do
    %{conn: conn, admin: admin, editor: editor} = ctx

    token = AshQuick.Impersonation.Token.sign(admin, editor)
    tab_conn = conn |> log_in(admin) |> in_tab(new_tab()) |> impersonating(token)

    {:ok, view, html} = live(tab_conn, ~p"/products")
    assert html =~ "You&#39;re impersonating #{editor.name}"

    # One second of max age, and one more so the remount finds it refused.
    assert_redirect(view, "/products", 3_000)

    {:ok, _again, html} = live(tab_conn, ~p"/products")
    refute html =~ "You&#39;re impersonating"
  end

  test "a max age of months arms its timer like any other", ctx do
    %{conn: conn, admin: admin, editor: editor} = ctx
    Application.put_env(:ash_quick, :impersonation_max_age, 100 * 24 * 60 * 60)

    token = AshQuick.Impersonation.Token.sign(admin, editor)
    tab_conn = conn |> log_in(admin) |> in_tab(new_tab()) |> impersonating(token)

    {:ok, _view, html} = live(tab_conn, ~p"/products")
    assert html =~ "You&#39;re impersonating #{editor.name}"
  end
end
