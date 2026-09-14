defmodule AshQuick.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/emadshaaban92/ash_quick"

  def project do
    [
      app: :ash_quick,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      # The suite defines Ash resources at compile time, and each one carries
      # its own `Inspect` implementation. Consolidated protocols would make
      # those runtime implementations warn, so leave them unconsolidated in
      # :test. See the `Protocol` module docs.
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      name: "AshQuick",
      description: "Declarative CRUD LiveViews for Ash resources",
      package: package(),
      docs: docs(),
      source_url: @source_url,
      # A translator wants to know which file a string lives in; nobody wants a
      # catalogue that churns every time a line is inserted above one.
      gettext: [write_reference_line_numbers: false]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # Required. The resource layer, its DSL toolkit, and the web layer every
      # QuickView renders through.
      {:ash, "~> 3.0"},
      {:ash_phoenix, "~> 2.0"},
      {:spark, "~> 2.0"},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_html, "~> 4.0"},
      {:gettext, "~> 1.0"},
      {:live_select, "~> 1.7"},
      {:jason, "~> 1.4"},

      # Optional. Each one turns a feature on; without it the feature is absent
      # rather than broken — see `AshQuick.Config.exports_enabled?/0` and
      # `print_enabled?/0`, and `AshQuick.Storage.S3`.
      #
      # Optional deps are still fetched for this project itself, so the suite
      # exercises the features rather than only the guards.
      {:nimble_csv, "~> 1.2", optional: true},
      {:exceed, "~> 0.6", optional: true},
      {:briefly, "~> 0.5", optional: true},
      {:chromic_pdf, "~> 1.17", optional: true},
      {:ex_aws, "~> 2.5", optional: true},
      {:ex_aws_s3, "~> 2.5", optional: true},
      {:ex_money, "~> 6.0", optional: true},
      {:localize, "~> 1.0", optional: true},
      {:merge_pdf, "~> 0.5", optional: true},
      {:tower, "~> 0.8", optional: true},

      # The installer and generators are mix tasks in this package, and a host
      # runs them in its own environment — so `only: [:dev, :test]` would leave
      # them uncompilable exactly where they are used. Optional, so a project
      # that never generates anything does not carry them.
      {:igniter, "~> 0.8", optional: true},
      {:sourceror, "~> 1.7", optional: true},

      # Tooling.
      {:lazy_html, ">= 0.0.0", only: :test},
      {:simple_sat, "~> 0.1", only: [:test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      # Spelled out, because three of these are not in Hex's default set and
      # each is load-bearing: `assets` is the client half a host imports into
      # its `app.js`, and `usage-rules.md` / `usage-rules` are what
      # `mix usage_rules.sync` delivers to a consuming project's agents.
      files: [
        "lib",
        "priv",
        "assets",
        "usage-rules.md",
        "usage-rules",
        ".formatter.exs",
        "mix.exs",
        "README.md",
        "LICENSE"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "usage-rules.md"]
    ]
  end
end
