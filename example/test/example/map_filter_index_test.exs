defmodule Example.MapFilterIndexTest do
  @moduledoc """
  A map row Postgres can answer from a GIN index on the column: Equals and
  Key Exists are asked as a bare `@?`, which `jsonb_path_ops` serves, and
  only the rows under a `not` wrap theirs in `coalesce`.

  Not async: the index is built on the audit trail's shared table, inside
  this test's sandbox transaction, and building one waits on every other
  transaction writing to that table.
  """
  use Example.DataCase, async: false

  alias AshQuick.LiveView.CustomFilter
  alias Example.Accounts.AuditLog

  setup do
    Repo.query!(
      "CREATE INDEX audit_logs_changes_path_ops ON audit_logs USING gin (changes jsonb_path_ops)"
    )

    # A handful of rows makes a sequential scan the cheapest plan; with it
    # off, Postgres takes the index wherever one can serve the filter.
    Repo.query!("SET LOCAL enable_seqscan = off")
    :ok
  end

  # Not Equals asks first that the key is there, bare too, so the index
  # narrows it to the rows holding the key.
  test "Equals, Key Exists and Not Equals are served by the index" do
    for {operator, value} <- [{"equals", "x"}, {"has_key", nil}, {"not_equals", "x"}] do
      assert plan(["k"], operator, value) =~ "audit_logs_changes_path_ops", operator
    end
  end

  defp plan(path, operator, value) do
    filter =
      CustomFilter.build_ash_filter(%CustomFilter{
        uuid: "root",
        operator: "and",
        children: [
          %CustomFilter{
            uuid: "row",
            field_name: "changes",
            path: path,
            operator: operator,
            value: value
          }
        ]
      })

    {:ok, query} =
      AuditLog
      |> Ash.Query.filter_input(filter)
      |> Ash.Query.data_layer_query()

    {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Repo, query)

    Repo.query!("EXPLAIN " <> sql, params).rows |> Enum.map_join("\n", &hd/1)
  end
end
