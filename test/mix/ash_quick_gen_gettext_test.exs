defmodule Mix.Tasks.AshQuick.Gen.GettextTest do
  @moduledoc """
  `mix ash_quick.gen.gettext` against a backend whose `priv` is a scratch
  directory, over the nav fixture.

  Not async: the backend and the nav are application config.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.AshQuick.Gen.Gettext, as: Task

  @priv "tmp/gen_gettext_test"
  @pot Path.join(@priv, "ash_quick.pot")
  @ar Path.join(@priv, "ar/LC_MESSAGES/ash_quick.po")

  setup do
    for {key, value} <- [gettext: AshQuick.Test.TaskGettext, nav: AshQuick.Test.Nav.Declared] do
      original = Application.get_env(:ash_quick, key)
      Application.put_env(:ash_quick, key, value)
      on_exit(fn -> Application.put_env(:ash_quick, key, original) end)
    end

    File.rm_rf!(@priv)
    on_exit(fn -> File.rm_rf!(@priv) end)

    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
  end

  test "writes the template into the backend's priv" do
    Task.run([])

    assert File.read!(@pot) =~ ~s(msgid "Marques")
    assert File.read!(@pot) =~ ~s(msgid "Cancel")
    assert_received {:mix_shell, :info, ["* writing " <> _]}
  end

  test "--check passes on a fresh template and fails on a stale one" do
    Task.run([])
    Task.run(["--check"])

    File.write!(@pot, File.read!(@pot) |> String.replace(~s(msgid "Marques"\nmsgstr ""\n\n), ""))

    assert_raise Mix.Error, ~r/out of date/, fn -> Task.run(["--check"]) end
  end

  test "--contexts writes the contexted labels too, and --check holds to them" do
    Task.run(["--contexts"])

    assert File.read!(@pot) =~ ~s(msgctxt "brand"\nmsgid "VAT Number")
    Task.run(["--check", "--contexts"])
    assert_raise Mix.Error, ~r/out of date/, fn -> Task.run(["--check"]) end
  end

  test "keeps a contexted translation added by hand through gettext.merge" do
    Task.run(["--locale", "ar"])
    Task.run([])
    Mix.Tasks.Gettext.Merge.run([@priv, "--no-fuzzy"])

    File.write!(
      @ar,
      File.read!(@ar) <> ~s(\nmsgctxt "brand"\nmsgid "VAT Number"\nmsgstr "رقم ضريبي"\n)
    )

    Task.run([])
    assert File.read!(@pot) =~ ~s(msgctxt "brand"\nmsgid "VAT Number")
    refute File.read!(@pot) =~ ~s(msgctxt "brand"\nmsgid "Name")

    Mix.Tasks.Gettext.Merge.run([@priv, "--no-fuzzy"])
    assert File.read!(@ar) =~ ~s(msgctxt "brand"\nmsgid "VAT Number"\nmsgstr "رقم ضريبي")
    Task.run(["--check"])
  end

  test "--check fails when there is no template" do
    assert_raise Mix.Error, ~r/out of date/, fn -> Task.run(["--check"]) end
    refute File.exists?(@pot)
  end

  test "--locale copies the seed, and leaves a translation already there alone" do
    Task.run(["--locale", "ar"])
    assert File.read!(@ar) == File.read!("priv/gettext_seeds/ar/LC_MESSAGES/ash_quick.po")

    mine = ~s(msgid "Mine"\nmsgstr "لي"\n)
    File.write!(@ar, mine)
    Task.run(["--locale", "ar"])
    assert File.read!(@ar) == mine
  end

  test "--locale with no seed says how to start one, and copies nothing" do
    Task.run(["--locale", "xx"])

    assert_received {:mix_shell, :info, ["AshQuick ships no xx translation" <> _]}
    refute File.exists?(Path.join(@priv, "xx"))
  end

  test "refuses to run with no backend to write into" do
    Application.delete_env(:ash_quick, :gettext)

    assert_raise Mix.Error, ~r/config :ash_quick, gettext:/, fn -> Task.run([]) end
  end
end
