defmodule ExampleWeb.LocaleScenarioTest do
  @moduledoc """
  The language a person's pages render in, and the direction they run.

  Everything AshQuick draws goes through `AshQuick.Gettext`, against whatever
  locale is on the process. The locale itself comes off the scope
  (`AshQuick.Scope.locale/1`), and `ExampleWeb.UserAuth` is what puts it there —
  once in the `:assign_scope` plug, for the render the browser gets first, and
  again at the LiveView mount.

  The mount also *pushes* it. The dead render already carried `lang` and `dir`,
  but it ran before the tab said who it is, so an impersonating tab's first
  paint is the real user's language. Only the connected mount knows the answer,
  which is why there is an event at all.

  A reader left on the default is the control throughout: an assertion that
  would pass whatever the locale is fails on them.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Accounts.User

  # AshQuick's own catalogue, not this application's — the point is that a host
  # gets the library's chrome translated without shipping a string for it.
  @search_en "Search"
  @search_ar "بحث"
  @export_ar "تصدير"

  describe "setting it" do
    test "an admin picks a language for somebody, and that person's pages turn over", ctx do
      %{conn: conn, admin: admin, editor: editor, viewer: viewer} = ctx

      product(name: "Four-season tent", actor: admin)

      conn
      |> log_in(admin)
      |> visit(~p"/users/#{editor.id}/update")
      # Offered by its `one_of` constraint, labelled through
      # `config :ash_quick, humanize_overrides:` — nothing on the QuickView
      # mentions the field.
      |> select_entry("Locale", "العربية")
      |> click_button("Save")

      assert Ash.reload!(editor, authorize?: false).locale == :ar

      # Their chrome is Arabic on a page neither they nor this app wrote a
      # string for.
      conn
      |> log_in(editor)
      |> visit(~p"/products")
      |> assert_has("label", text: @search_ar)
      |> assert_has("*", text: @export_ar)
      |> refute_has("label", text: @search_en)

      # The control: a reader nobody touched still gets English on the same
      # page, so the assertions above are about the locale rather than about
      # those strings never rendering.
      conn
      |> log_in(viewer)
      |> visit(~p"/products")
      |> assert_has("label", text: @search_en)
      |> refute_has("label", text: @search_ar)
    end

    test "the connected mount tells the browser, because the first render could not", ctx do
      %{conn: conn, admin: admin, editor: editor} = ctx

      arabic = Ash.update!(editor, %{locale: :ar}, actor: admin)

      {:ok, view, _html} = live(log_in(conn, arabic), ~p"/products")

      # `deps/ash_quick/assets/js/locale.js` is what puts these on `<html>`.
      # Without the direction the whole layout runs the wrong way while every
      # string is correct, which is the harder half to notice.
      assert_push_event(view, "locale", %{lang: "ar", dir: "rtl"})

      {:ok, english_view, _html} = live(log_in(conn, admin), ~p"/products")
      assert_push_event(english_view, "locale", %{lang: "en", dir: "ltr"})
    end

    test "a language nobody set is the configured default, not nothing", ctx do
      %{conn: conn, viewer: viewer} = ctx

      # `AshQuick.Scope.locale/1` falls back to `AshQuick.Config.locale/0`, so a
      # scope that states nothing still resolves to a real locale rather than
      # leaving Gettext on whatever the last process set.
      assert viewer.locale == :en
      assert AshQuick.Config.locale() == "en"
      assert AshQuick.Scope.locale(Example.Scope.new()) == "en"
      assert AshQuick.Locale.direction("ar") == "rtl"
      assert AshQuick.Locale.direction("en") == "ltr"
    end
  end

  describe "a tab standing in for somebody" do
    test "is told their language, which the first render could not have known", ctx do
      %{conn: conn, admin: admin, editor: editor} = ctx

      arabic = Ash.update!(editor, %{locale: :ar}, actor: admin)
      token = impersonation_token(conn, admin, arabic)

      # The admin reads English. The dead render is theirs — it ran before the
      # connect params named the tab — so what corrects it is the pushed event.
      {:ok, view, _html} = live(conn |> log_in(admin) |> impersonating(token), ~p"/products")

      assert_push_event(view, "locale", %{lang: "ar", dir: "rtl"})

      # And the page itself is in the language of whoever the tab is acting as,
      # which is the point: support sees what the person reporting the problem
      # sees.
      conn
      |> log_in(admin)
      |> impersonating(token)
      |> visit(~p"/products")
      |> assert_has("label", text: @search_ar)
      |> assert_has("[data-ash-quick-impersonating]")

      # The admin's own other tab is unmoved, so the locale follows the tab
      # rather than the login.
      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> assert_has("label", text: @search_en)
    end

    test "and a tab that is nobody but itself is told the default", ctx do
      %{conn: conn, admin: admin} = ctx

      # Always pushed, even when it says nothing new. A message sent only on
      # change would leave a tab that had just ended an impersonation still
      # laid out right-to-left.
      {:ok, view, _html} = live(log_in(conn, admin), ~p"/")

      assert_push_event(view, "locale", %{lang: "en", dir: "ltr"})
    end
  end

  describe "who may set one" do
    test "a language is the reader's own business, unlike their role", ctx do
      %{admin: admin, editor: editor} = ctx

      # `:role` is restricted to admins by `Example.Checks.RoleIsAdminOnly`;
      # `:locale` deliberately is not. Both are on the same action, so this pins
      # that the restriction is per field rather than per form.
      restricted =
        User
        |> AshQuick.FieldRestrictions.Info.restricted_fields(:update)
        |> Enum.map(& &1.field)

      assert :role in restricted
      refute :locale in restricted

      assert Ash.update!(editor, %{locale: :ar}, actor: admin).locale == :ar
    end
  end

  defp impersonation_token(conn, real_actor, target) do
    target_tab = new_tab()

    {:ok, _target_view, _html} =
      live(conn |> log_in(target) |> in_tab(target_tab), ~p"/products")

    {:ok, console, _html} = live(log_in(conn, real_actor), ~p"/browser_sessions")

    console
    |> element("#session-#{target_tab["id"]} button", "Open as them")
    |> render_click()

    assert_push_event(console, "impersonate", %{token: token})
    token
  end
end
