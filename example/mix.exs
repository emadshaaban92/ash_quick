defmodule Example.MixProject do
  use Mix.Project

  @moduledoc """
  The example host application for AshQuick.

  It exists to be a *host*: the library has no Repo, no endpoint and no router
  of its own, so the paths that only exist inside a real Phoenix + AshPostgres
  application — the optimistic lock's `before_action` filter reaching SQL, a
  presign taking custody in a transaction, a QuickView rendered end to end
  behind a session — can only be tested here. Everything it demonstrates is a
  by-product of that.
  """

  def project do
    [
      app: :example,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      consolidate_protocols: Mix.env() != :dev,
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [
      mod: {Example.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [preferred_envs: [coveralls: :test, "coveralls.html": :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # The library under test, from the checkout this app lives in.
      {:ash_quick, path: ".."},
      {:ash, "~> 3.36"},
      {:ash_phoenix, "~> 2.3"},
      {:ash_postgres, "~> 2.14"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, ">= 0.0.0"},
      {:picosat_elixir, "~> 0.2"},
      {:phoenix, "~> 1.8.5"},
      {:phoenix_ecto, "~> 4.7"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_live_reload, "~> 1.7", only: :dev},
      {:phoenix_live_dashboard, "~> 0.9"},
      {:bandit, "~> 1.12"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:live_select, "~> 1.7"},
      {:telemetry_metrics, "~> 1.2"},
      {:telemetry_poller, "~> 1.3"},

      # Assets.
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},

      # AshQuick's optional dependencies, so the features they gate are the
      # ones this app demonstrates and tests:
      #
      #   * `exceed` + `nimble_csv` + `briefly` — the export menu on every list
      #     (the first two are what `AshQuick.Config.exports_enabled?/0` looks
      #     for; `briefly` is what the generated file is written through).
      #   * `ex_aws` + `ex_aws_s3` — presigned upload and download URLs.
      #   * `ash_money` + `ex_money_sql` — a `Money` column rendered on a page.
      #
      # `chromic_pdf` is deliberately absent: printing would want a Chrome on
      # the machine. No action here carries `AshQuick.Print`, and one that did
      # would not compile without it.
      {:exceed, "~> 0.7"},
      {:nimble_csv, "~> 1.3"},
      {:briefly, "~> 0.5"},
      {:ex_aws, "~> 2.7"},
      {:ex_aws_s3, "~> 2.5"},
      {:ash_money, "~> 0.2"},
      {:ex_money_sql, "~> 2.1"},

      # Tooling.
      {:igniter, "~> 0.8", only: [:dev, :test]},
      {:sourceror, "~> 1.12", only: [:dev, :test]},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_test, "~> 0.12", only: :test, runtime: false},
      # What ExAws parses a multipart upload's responses with. Only reached
      # through `Example.Test.S3Stub`, which is the only bucket this app talks to.
      {:sweet_xml, "~> 0.7", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:tidewave, "~> 0.9", only: [:dev]}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ash.setup", "assets.setup", "assets.build", "run priv/repo/seeds.exs"],
      # Overrides Ash's own `ash.reset` (tear_down + setup) to re-seed as well,
      # which is what makes it the one command to get back to a known state.
      "ash.reset": ["ash.tear_down", "ash.setup", "run priv/repo/seeds.exs"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind example", "esbuild example"],
      "assets.deploy": ["tailwind example --minify", "esbuild example --minify", "phx.digest"]
    ]
  end
end
