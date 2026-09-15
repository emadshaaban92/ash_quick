defmodule ExampleWeb.ImpersonationScenarioTest do
  @moduledoc """
  One admin browsing as somebody else, from the console that starts it to the
  kill switch that ends it.

  Impersonation belongs to a **browser tab**, not to an account. The token lives
  in the tab's `sessionStorage` and rides the LiveSocket connect params, so the
  same signed-in admin is two different people in two windows — which is the
  property most of these tests are really about, and the reason
  `ExampleWeb.Sessions` can mint and replay a tab identity by hand.

  It is also the feature with the most ways to go quietly wrong: a tab that is
  somebody else and does not say so, a write filed under the person who was not
  at the keyboard, or a revocation that leaves the tab impersonating anyway.
  Each is a whole-page outcome, so each is driven.

  The register is process-backed and global — `AshQuick.BrowserSessionPresence`
  is not in the sandbox — so every assertion here is scoped to a tab id this
  test minted. Asserting on the *set* of live sessions would see other async
  tests' tabs.
  """
  use ExampleWeb.FeatureCase, async: true

  require Ash.Query

  alias Example.Accounts.{AuditLog, User}
  alias Example.Catalog.Product

  setup %{admin: admin} do
    %{product: product(name: "Four-season tent", actor: admin)}
  end

  describe "starting one" do
    test "the console lists a live tab, and opening it hands back a token", ctx do
      %{conn: conn, admin: admin, editor: editor} = ctx

      # The editor is sitting on a page. That connection is the whole of what
      # puts them in the register — no row anywhere records who is looking at
      # what, so the register tracks it on the LiveView process itself.
      editor_tab = new_tab()

      {:ok, _editor_view, _html} =
        live(conn |> log_in(editor) |> in_tab(editor_tab), ~p"/products")

      {:ok, console, _html} = live(log_in(conn, admin), ~p"/browser_sessions")

      assert has_element?(console, "#session-#{editor_tab["id"]}")
      assert render(console) =~ editor.name

      console
      |> element("#session-#{editor_tab["id"]} button", "Open as them")
      |> render_click()

      # The token is pushed to the client rather than redirected to, because
      # only the browser can put it where the next connection will replay it.
      assert_push_event(console, "impersonate", %{token: token, to: to})
      assert to == "/products"
      assert is_binary(token)
    end

    test "which resolves to that person, and says so on every page", ctx do
      %{conn: conn, admin: admin, editor: editor} = ctx

      token = impersonation_token(conn, admin, editor)

      # The interlock: a tab standing in for somebody is never silent about it.
      conn
      |> log_in(admin)
      |> impersonating(token)
      |> visit(~p"/products")
      |> assert_has("[data-ash-quick-impersonating]", text: "You're impersonating #{editor.name}")
      |> assert_has("[data-ash-quick-impersonating] button", text: "End")

      # And on the next page too. A fresh conn rather than a second `visit/2` on
      # the same session, because the token is a *connect param*: the browser
      # replays it on every connection, and a tab that only said so once would
      # be the exact failure this banner exists to prevent.
      conn
      |> log_in(admin)
      |> impersonating(token)
      |> visit(~p"/brands")
      |> assert_has("[data-ash-quick-impersonating]", text: "You're impersonating #{editor.name}")
    end

    test "an impersonation is the only record that it happened", ctx do
      %{conn: conn, admin: admin, editor: editor} = ctx

      before = Ash.reload!(editor, authorize?: false)
      impersonation_token(conn, admin, editor)
      after_ = Ash.reload!(editor, authorize?: false)

      # `AshQuick.Impersonation.NoOp` hands the record straight back, so the
      # action writes nothing — not even the optimistic lock moves.
      assert after_.version == before.version
      assert after_.updated_at == before.updated_at

      entry =
        AuditLog
        |> Ash.Query.filter(resource_id == ^editor.id and action_name == :impersonate)
        |> Ash.read_one!(authorize?: false, load: [:actor, :real_actor])

      assert entry.actor.id == admin.id
      assert entry.resource_name == Ash.Resource.Info.short_name(User)
    end
  end

  describe "acting as somebody else" do
    test "a write names them, and names the person who was really at the keyboard", ctx do
      %{conn: conn, admin: admin, editor: editor, product: product} = ctx

      token = impersonation_token(conn, admin, editor)

      conn
      |> log_in(admin)
      |> impersonating(token)
      |> visit(~p"/products/#{product.id}/update")
      |> fill_in("Name", with: "Renamed while impersonating")
      |> click_button("Save")
      |> assert_has("h1", text: "Renamed while impersonating")

      entry =
        AuditLog
        |> Ash.Query.filter(resource_id == ^product.id and action_name == :update)
        |> Ash.read_one!(authorize?: false, load: [:actor, :real_actor])

      # Both halves. Without `real_actor` the trail would say the editor did it,
      # which is the attribution an impersonation exists to avoid losing.
      assert entry.actor.id == editor.id
      assert entry.real_actor.id == admin.id

      # And the record's own bookkeeping names who it was done as.
      assert Ash.reload!(product, authorize?: false).updated_by_id == editor.id
    end

    test "is refused what that person is refused, not what the admin may do", ctx do
      %{conn: conn, admin: admin, viewer: viewer, product: product} = ctx

      token = impersonation_token(conn, admin, viewer)

      # A viewer writes nothing, so neither does an admin standing in for one —
      # the scope's actor is who the policies are asked about.
      conn
      |> log_in(admin)
      |> impersonating(token)
      |> visit(~p"/products/#{product.id}")
      |> refute_has("button", text: "Update")

      # Reaching past the missing control lands on the refusal rather than the
      # form, and the record is untouched.
      conn
      |> log_in(admin)
      |> impersonating(token)
      |> visit(~p"/products/#{product.id}/update")
      |> refute_has("form")

      assert Ash.reload!(product, authorize?: false).name == "Four-season tent"
    end

    test "a route that person does not hold sends them somewhere they can be", ctx do
      %{conn: conn, admin: admin, viewer: viewer} = ctx

      token = impersonation_token(conn, admin, viewer)

      # Not a 403. The dead render ran as the admin, who can reach `/users`, so
      # only the connected mount fails — and the reload the client answers with
      # would land on the same page and fail again. The gate takes them home and
      # says why instead.
      impersonating_conn = conn |> log_in(admin) |> impersonating(token)

      assert {:ok, _view, html} =
               impersonating_conn
               |> live(~p"/users")
               |> follow_redirect(impersonating_conn, ~p"/")

      # They land somewhere they really can be as this person, and are told why
      # they were moved.
      assert html =~ "can&#39;t access /users"
      assert html =~ "You&#39;re impersonating #{viewer.name}"
    end

    test "only the tab holding the token is anybody else", ctx do
      %{conn: conn, admin: admin, editor: editor} = ctx

      token = impersonation_token(conn, admin, editor)

      # Same signed-in admin, second window. Impersonation is per tab, so this
      # one is still themselves — the property that makes support work possible
      # without giving up your own session.
      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> refute_has("[data-ash-quick-impersonating]")
      # `/users` is the admin's, and unreachable in the tab above.
      |> visit(~p"/users")
      |> assert_has("td", text: editor.name)

      conn
      |> log_in(admin)
      |> impersonating(token)
      |> visit(~p"/products")
      |> assert_has("[data-ash-quick-impersonating]")
    end
  end

  describe "ending one" do
    test "the console revokes it, and the tab is told to drop its token", ctx do
      %{conn: conn, admin: admin, editor: editor} = ctx

      token = impersonation_token(conn, admin, editor)

      impersonating_tab = new_tab()

      {:ok, impersonating_view, html} =
        live(
          conn |> log_in(admin) |> in_tab(impersonating_tab) |> impersonating(token),
          ~p"/products"
        )

      assert html =~ "You&#39;re impersonating #{editor.name}"

      # The console sees it as an impersonation rather than as an ordinary
      # session, which is what makes it revokable at all.
      {:ok, console, _html} = live(log_in(conn, admin), ~p"/browser_sessions")
      row = "#session-#{impersonating_tab["id"]}"

      assert has_element?(console, row)
      assert console |> element(row) |> render() =~ "Impersonating"

      console |> element("#{row} button", "End") |> render_click()

      # The kill switch is a message to the tab's own process: the client drops
      # the token and reconnects as whoever is really signed in. Nothing the
      # server holds had to change, because the impersonation was never there.
      assert_push_event(impersonating_view, "end-impersonation", %{})
    end

    test "an ordinary session is not something this page ends", ctx do
      %{conn: conn, admin: admin, editor: editor} = ctx

      editor_tab = new_tab()

      {:ok, _editor_view, _html} =
        live(conn |> log_in(editor) |> in_tab(editor_tab), ~p"/products")

      {:ok, console, _html} = live(log_in(conn, admin), ~p"/browser_sessions")
      row = "#session-#{editor_tab["id"]}"

      # The row is there and offers the impersonate control, so the refutal
      # below is about this control and not about an empty page.
      assert has_element?(console, "#{row} button", "Open as them")
      refute has_element?(console, "#{row} button", "End")

      # Ending somebody's *login* is not an act this library performs, so the
      # forged event is refused rather than merely unoffered — and the editor's
      # tab is still registered afterwards.
      render_click(console, "revoke", %{"id" => editor_tab["id"]})

      {:ok, reloaded, _html} = live(log_in(conn, admin), ~p"/browser_sessions")
      assert has_element?(reloaded, row)
    end
  end

  describe "who may stand in for whom" do
    test "nobody stands in for themselves", ctx do
      %{conn: conn, admin: admin} = ctx

      admin_tab = new_tab()

      {:ok, _own_view, _html} =
        live(conn |> log_in(admin) |> in_tab(admin_tab), ~p"/products")

      {:ok, console, _html} = live(log_in(conn, admin), ~p"/browser_sessions")
      row = "#session-#{admin_tab["id"]}"

      assert has_element?(console, row)
      refute has_element?(console, "#{row} button", "Open as them")

      refute Ash.can?({admin, :impersonate}, admin)
    end

    test "a role the policy refuses holds no route to the console either", ctx do
      %{conn: conn, admin: admin, editor: editor, viewer: viewer} = ctx

      # Two boundaries, and each is worth its own: the policy refuses the act,
      # and the access control refuses the page that offers it.
      refute Ash.can?({editor, :impersonate}, viewer)
      refute Ash.can?({admin, :impersonate}, editor)

      for refused <- [editor, viewer] do
        assert_raise ExampleWeb.NotAllowedError, fn ->
          live(log_in(conn, refused), ~p"/browser_sessions")
        end
      end
    end

    test "and neither QuickView surface offers the action at all", ctx do
      %{conn: conn, admin: admin, editor: editor} = ctx

      # Starting an impersonation means minting the tab's token, which only
      # `/browser_sessions` does. A QuickView button would run the action —
      # writing an audit entry for an impersonation that never happened — and
      # then leave the page exactly where it was, so the policy forbids both
      # surfaces by their `action_source`.
      conn
      |> log_in(admin)
      |> visit(~p"/users/#{editor.id}")
      |> refute_has("button", text: "Impersonate")
      |> refute_has("a", text: "Impersonate")

      # The details page does offer other actions, so the refutal above is not
      # passing for want of any controls.
      |> assert_has("button", text: "Update")

      conn
      |> log_in(admin)
      |> visit(~p"/users")
      |> open_row_actions(editor.id)
      |> refute_has("a[id='#{editor.id}-action-impersonate']")
      |> assert_has("a[id='#{editor.id}-action-update']")

      # Forged from the list anyway, it is refused rather than merely unoffered.
      |> force_row_action(editor.id, :impersonate)

      assert impersonations_of(editor.id) == []
    end
  end

  # Runs exactly what the console runs when its button is clicked, and hands
  # back the token it pushed. Used by the tests that are about what a tab
  # holding one *does*, rather than about how it came by it — which the first
  # `describe` drives through the page.
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

  defp impersonations_of(user_id) do
    AuditLog
    |> Ash.Query.filter(resource_id == ^user_id and action_name == :impersonate)
    |> Ash.read!(authorize?: false)
  end
end
