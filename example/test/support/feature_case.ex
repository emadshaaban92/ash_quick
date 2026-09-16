defmodule ExampleWeb.FeatureCase do
  @moduledoc """
  Tests that drive a page the way a person does.

  `PhoenixTest` is the surface: `visit/2`, `fill_in/3`, `click_button/2`,
  `assert_has/3`. The assertions land on what is rendered rather than on which
  element carries which `phx-click`, which is the point — a QuickView's buttons,
  columns and row actions are derived from the resource, and a test that names
  the derivation rather than the result would pass while the page was blank.

      conn
      |> log_in(admin)
      |> visit(~p"/products")
      |> click_button("Add Product")
      |> fill_in("Name", with: "Four-season tent")
      |> click_button("Save")
      |> assert_has("td", text: "Four-season tent")

  Two things PhoenixTest cannot express, and what to use instead:

    * **A control that is not there.** `refute_has/3` is the assertion, but
      match it on something only that control renders. A `refute_has("button",
      text: "Update")` passes for the wrong reason on any page with an "Updated
      At" label.
    * **An event nobody could click.** Hiding a button is UI; the policy behind
      it is the boundary, and only a hand-sent event tests it. `unwrap/2`
      reaches the LiveView, and `Phoenix.LiveViewTest.render_click/3` pushes the
      event exactly as someone editing the DOM in DevTools would.

  Use `ExampleWeb.ConnCase` instead when the test is about a response rather
  than a page, and `Example.DataCase` when it never reaches one.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint ExampleWeb.Endpoint

      use ExampleWeb, :verified_routes

      import Example.Fixtures
      import ExampleWeb.QuickViewHelpers
      import ExampleWeb.Sessions
      import PhoenixTest

      # For the boundary tests `unwrap/2` hands back a LiveView to, and for the
      # `live/2` mount a test asserts raises before any page exists. `live/2`
      # expands to a `get/2` in the caller, which is why `Phoenix.ConnTest`
      # comes with it.
      import Phoenix.ConnTest, only: [build_conn: 0, get: 2]

      import Phoenix.LiveViewTest, except: [open_browser: 1, open_browser: 2]
    end
  end

  setup tags do
    Example.DataCase.setup_sandbox(tags)

    {:ok, Map.merge(Example.Fixtures.roles(), %{conn: Phoenix.ConnTest.build_conn()})}
  end
end
