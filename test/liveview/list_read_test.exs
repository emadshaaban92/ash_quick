defmodule AshQuick.LiveView.ListReadTest do
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.ListRead

  defp unknown(error), do: Ash.Error.Unknown.UnknownError.exception(error: error)

  describe "timed_out?/1" do
    # Postgres's `statement_timeout`, as AshPostgres raises it, whole or
    # rendered to text by the time it is rescued.
    test "is true for a statement Postgres cancelled" do
      canceled = %{__struct__: Postgrex.Error, postgres: %{code: :query_canceled}}

      assert ListRead.timed_out?(unknown(canceled))

      assert ListRead.timed_out?(
               unknown(
                 "** (Postgrex.Error) ERROR 57014 (query_canceled) canceling statement due to statement timeout"
               )
             )
    end

    # A pool says the same of a connection it dropped as of one that ran
    # out of time, so neither is told to the visitor as a slow filter.
    test "is false for a connection error, whatever its cause" do
      for message <- [
            "connection is closed because of an error, disconnect or timeout",
            "tcp recv (idle): timeout"
          ] do
        refute ListRead.timed_out?(
                 unknown(%{__struct__: DBConnection.ConnectionError, message: message})
               )

        refute ListRead.timed_out?(unknown("** (DBConnection.ConnectionError) #{message}"))
      end
    end

    test "is false for a value the data layer refused, or any other error" do
      refute ListRead.timed_out?(
               unknown("** (Ecto.Query.CastError) value `\"x\"` cannot be cast")
             )

      refute ListRead.timed_out?(
               unknown(%{__struct__: Postgrex.Error, postgres: %{code: :undefined_column}})
             )

      refute ListRead.timed_out?(Ash.Error.Invalid.exception(errors: []))
    end
  end
end
