ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Example.Repo, :manual)

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
