defmodule AshQuick.Identity.Verifier do
  @moduledoc false
  # Refuses to compile a resource carrying AshQuick whose rows an `:id` does not
  # address: one without the attribute at all, or one where the attribute does
  # not single out a row.
  #
  # AshQuick's views address a row by `:id`, and none of it is about what the
  # record is called. `AshQuick.LiveView.Components.ListView` builds its DOM ids
  # out of `record.id` (`"#{id}-row-actions-dropdown"`, `"#{id}-action-#{name}"`)
  # and pushes the same value back over the socket as `%{id: record.id}` for
  # `row_actions_open` and `row_action_click`, which
  # `AshQuick.LiveView.ListUtils` then resolves the record from. The details
  # route (`/brands/:id`) is the same requirement seen from the router.
  #
  # So a resource without one does not merely render a poor label — its row
  # actions have no identity to send back, and every row's DOM ids collide with
  # every other row's. Composite-keyed join resources are the realistic way in:
  # a membership resource keying on a pair of `belongs_to`s has no `:id`, and
  # `AshQuick`'s requirement that every resource it names carries the extension
  # puts one a single ordinary PR away.
  #
  # Uniqueness is the same requirement and not a second one, which is why both
  # halves live here: `AshQuick.LiveView.DetailsUtils.load_record!/3` filters
  # `id == ^id` and takes the answer through `Ash.read_one/2`, and
  # `ListUtils.do_action/4` finds the first record on the page whose `:id`
  # matches what was clicked. A repeated `:id` makes the first answer with an
  # error the details page renders as not-found, and the second hand back
  # whichever row was loaded first.
  #
  # What is deliberately not required is that `:id` be the primary key. The
  # views read the attribute and never `Ash.Resource.Info.primary_key/1`, so a
  # resource keyed on something else satisfies them by declaring the uniqueness
  # its `:id` already has.
  #
  # Not a reason, so nobody re-derives it: the list view does not sort by `:id`.
  # `sort_by` has no default, and `ListUtils.maybe_apply_sort(query, nil)` is the
  # identity — a list is unsorted unless a QuickView opts in.
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @impl true
  def verify(dsl_state) do
    cond do
      is_nil(Ash.Resource.Info.attribute(dsl_state, :id)) -> {:error, missing_error(dsl_state)}
      unique_id?(dsl_state) -> :ok
      true -> {:error, ambiguous_error(dsl_state)}
    end
  end

  # Sole primary key, or an identity over `:id` alone. `:id` as one column of a
  # composite key is neither — it repeats across the rows sharing it.
  defp unique_id?(dsl_state) do
    Ash.Resource.Info.primary_key(dsl_state) == [:id] or
      Enum.any?(Ash.Resource.Info.identities(dsl_state), &(&1.keys == [:id]))
  end

  defp missing_error(dsl_state) do
    error(dsl_state, """
    #{module(dsl_state)} carries the AshQuick extension and has no `:id` attribute.

    AshQuick addresses a row by `:id`: a list row's DOM ids are built from it, \
    the row-action events push it back over the socket to say which record was \
    clicked, and a details route is `/<path>/:id`. Without one, every row in a \
    list shares the same element ids and no row action can name its record.

    This is about identity and not about labelling — what a record is called \
    is declared separately, under `ash_quick do display do label ... end end`.

    Either give the resource a surrogate key:

        attributes do
          uuid_primary_key :id
        end

    or drop the extension from a resource no QuickView will ever render. A \
    composite-keyed join resource is usually the second: adding a surrogate \
    key to one means dropping the composite primary key and re-adding the pair \
    as a unique identity, which is worth doing when a page needs it and not \
    before.
    """)
  end

  defp ambiguous_error(dsl_state) do
    error(dsl_state, """
    #{module(dsl_state)} carries the AshQuick extension and nothing makes its `:id` unique.

    AshQuick addresses a row by `:id` and expects one row back. The details \
    query filters `id == ^id` and reads it through `Ash.read_one/2`, which \
    answers with an error rather than a record when two rows match — the page \
    renders as not-found. A row action resolves its record by the first `:id` \
    on the page that matches, which is not necessarily the row clicked.

    Make `:id` the primary key:

        attributes do
          uuid_primary_key :id
        end

    or, when the resource is keyed on something else, declare the uniqueness \
    its `:id` already has:

        identities do
          identity :unique_id, [:id]
        end

    `:id` as one column of a composite primary key is neither — it repeats \
    across every row sharing it.
    """)
  end

  defp error(dsl_state, message) do
    Spark.Error.DslError.exception(
      module: Verifier.get_persisted(dsl_state, :module),
      path: [:ash_quick],
      message: message
    )
  end

  defp module(dsl_state), do: inspect(Verifier.get_persisted(dsl_state, :module))
end
