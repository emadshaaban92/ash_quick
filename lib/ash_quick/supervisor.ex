defmodule AshQuick.Supervisor do
  @moduledoc """
  Every process AshQuick runs, under one supervisor the host starts as
  `AshQuick` (see `AshQuick.child_spec/1`).

  The host's tree names the library once, after the PubSub server and before
  the endpoint, and whatever AshQuick needs running comes and goes under it
  without the host's tree changing:

      children = [
        {Phoenix.PubSub, name: MyApp.PubSub},
        AshQuick,
        MyAppWeb.Endpoint
      ]

  After the PubSub server, because what runs here rides on it, and before the
  endpoint, so that no page is served before the register of signed-in tabs
  can count it.

  What runs here today is `AshQuick.BrowserSessionPresence`, the live register
  of signed-in tabs. It rides the PubSub server the configured `:endpoint`
  names in its own configuration, so nothing is configured for it. A host
  whose endpoint is configured under another application's name than its own
  passes `pubsub_server:`:

      {AshQuick, pubsub_server: MyApp.PubSub}

  It is not an OTP application of its own, started by `mod:` before the
  host's: the host's PubSub server does not exist yet at that point.

  Leaving it out of the tree costs the register and nothing else. The mount
  warns once per navigation and serves the page; only
  `AshQuick.LiveView.BrowserSessionsLive`, which reads the register, fails.
  """

  use Supervisor

  @doc false
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    children = [
      {AshQuick.BrowserSessionPresence, opts}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
