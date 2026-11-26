defmodule ExampleWeb.BrowserCase do
  @moduledoc """
  Tests that drive a page in a real browser: Chromium, through Playwright.

  The surface is `PhoenixTest` again, the same `visit/2`, `fill_in/3` and
  `assert_has/3` as `ExampleWeb.FeatureCase`, plus what only a browser has:
  `type/3` and `press/3` send real keystrokes to the focused element, and
  `evaluate/3` reads the page. `PhoenixTest.Playwright` documents them. Every
  assertion waits for the page to catch up, so a test never sleeps.

  These cover what `Phoenix.LiveViewTest` cannot reach: the JavaScript
  AshQuick ships, which only a browser runs. Its colocated hooks (the picker,
  the menus, the action modal, the lock on a submitting form, the zoned
  datetime input, the image viewer and the Copy button), its `S3` uploader,
  the listeners `attachAshQuick` adds (a tab's impersonation, the page's
  language, downloads and printed PDFs) and the sidebar's `JS` commands each
  have a file under `test/browser/`. `ExampleWeb.PickerDriver` stands in for
  the picker's hook rather than exercising it.

  Tagged `:playwright` and excluded by default. Run them with

      npm ci --prefix assets
      (cd assets && npx playwright install chromium)
      MIX_ENV=test mix assets.build
      mix test --only playwright

  The app serves the pages from the test build, and the browser's requests and
  LiveViews share the test's database transaction (`ExampleWeb.SqlSandbox`).
  The ETS tables behind the test resources are not sandboxed, so these run one
  at a time.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use PhoenixTest.Playwright.Case, async: false

      use ExampleWeb, :verified_routes

      import Example.Fixtures
      import ExampleWeb.BrowserCase

      @moduletag :playwright
    end
  end

  @doc "Signs `user` in for the rest of the browser session."
  def log_in(session, user) do
    PhoenixTest.Playwright.add_session_cookie(
      session,
      [value: %{user_id: user.id}],
      ExampleWeb.Endpoint.session_options()
    )
  end

  @doc """
  Waits until the page's LiveView has connected, so an event the test sends
  next reaches it.
  """
  def connected(session), do: PhoenixTest.assert_has(session, "[data-phx-main].phx-connected")

  @doc "The value of `expression`, evaluated in the page."
  def read(session, expression) do
    ref = make_ref()
    PhoenixTest.Playwright.evaluate(session, expression, &send(self(), {ref, &1}))

    receive do
      {^ref, value} -> value
    end
  end
end
