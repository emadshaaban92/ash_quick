ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Example.Repo, :manual)

# Ash's Ets data layer registers a table's manager before the manager creates
# the table, so two async tests that touch it first at once can read the gap as
# `:table_not_found`. Creating each table up front closes it.
for resource <- [
      Example.Test.BulkGuarded,
      Example.Test.DigitsOnly,
      Example.Test.RequiredAttachments,
      Example.Test.RequiredEntries,
      Example.Test.RequiredPicks,
      Example.Test.SmallPages,
      Example.Test.WordedPolicy
    ] do
  {:ok, _table} = Ash.DataLayer.Ets.TableManager.start(resource, nil)
end

# The bucket exports are written to. See `Example.Test.S3Stub`.
Example.Test.S3Stub.start()

# Under coverage, also instrument the library — the code under test, exercised
# only through this app. Plain `mix test` skips this.
if Process.whereis(:cover_server) do
  [Mix.Project.build_path(), "lib", "ash_quick", "ebin"]
  |> Path.join()
  |> String.to_charlist()
  |> :cover.compile_beam_directory()
end
