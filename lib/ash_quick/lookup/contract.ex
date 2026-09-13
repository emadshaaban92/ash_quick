defmodule AshQuick.Lookup.Contract do
  @moduledoc false
  # What every caller of a lookup action needs of it, in one place
  # so the resource-level verifier and the QuickView's compile-time check cannot
  # disagree about what "a usable lookup action" means.
  #
  # Each requirement is a call site rather than a preference:
  #
  #   * it exists, because `Ash.Query.for_read/4` raises on a name the resource
  #     does not define;
  #   * it takes the search argument and takes it as optional, because all four
  #     readers pass it — `ListUtils.load_data!/3`,
  #     `ListUtils.build_export_query/4`, `BelongsToInput` and `HasManyInput` —
  #     and all four pass `nil` through it when there is nothing to search for.
  #     An `allow_nil?: false` argument turns every unsearched read into an
  #     `Ash.Query.require_arguments/2` error: the list page under an empty box,
  #     and every dropdown the moment it opens;
  #   * it paginates, because the list reads the answer back through
  #     `Ash.Query.page/2` and both dropdowns read `.results` off it. An action
  #     without a `pagination` block hands back a bare list, so the failure
  #     lands at the reader as `expected a map, got: []` rather than anywhere
  #     near the action;
  #   * its pagination carries a `default_limit`, because a dropdown opens on
  #     `Ash.Query.page(count: false)` and passes no limit of its own. This is
  #     the one that survives every other check: the list page escapes it by
  #     always passing `limit:`, so the action reads perfectly well right up
  #     until someone opens a dropdown onto it and gets `* Limit is required`
  #     — or, under `required? false`, the bare list and `expected a map, got:
  #     []` again.

  alias AshQuick.Lookup.Declaration

  @doc """
  `:ok`, or `{:error, reason}` naming which requirement a resource's lookup
  action fails.

  Takes a compiled resource or an in-flight DSL state.
  """
  def check(dsl_or_resource, action_name, search_argument) do
    case Ash.Resource.Info.action(dsl_or_resource, action_name) do
      nil -> {:error, :missing_action}
      %{type: :read} = action -> check_read(action, search_argument)
      %{type: type} -> {:error, {:not_a_read, type}}
    end
  end

  @doc """
  Checks the resource's own declaration, for a caller holding nothing but the
  resource.
  """
  def check(dsl_or_resource) do
    check(
      dsl_or_resource,
      Declaration.action(dsl_or_resource),
      Declaration.search_argument(dsl_or_resource)
    )
  end

  @doc """
  The checked lookup action of `resource`, or a raise carrying `context` and the
  fix.

  For the callers that hold a resource and need its action anyway: the
  QuickView's compile-time check and the two dropdown components. `action_name`
  overrides what the resource declared, which is how a QuickView's
  `list: [default_action: ...]` is held to the same contract as the rest.

  The extension is checked first so that a destination carrying none is named
  along with whatever points at it. Resolving the action would otherwise raise
  out of `AshQuick.Info` before this ever runs, and that raise knows only the
  resource — not the dropdown that led here, which is the half the reader
  cannot guess.
  """
  def check!(resource, action_name \\ nil, context) do
    if AshQuick in Spark.extensions(resource) do
      action_name = action_name || Declaration.action(resource)

      case check(resource, action_name, Declaration.search_argument(resource)) do
        :ok -> action_name
        {:error, reason} -> raise ArgumentError, message(resource, action_name, reason, context)
      end
    else
      raise ArgumentError, message(resource, action_name, :missing_extension, context)
    end
  end

  defp check_read(action, search_argument) do
    argument = Enum.find(action.arguments, &(&1.name == search_argument))

    cond do
      is_nil(argument) ->
        {:error, {:missing_argument, search_argument}}

      argument.allow_nil? == false ->
        {:error, {:required_argument, search_argument}}

      action.pagination in [nil, false] ->
        {:error, :no_pagination}

      is_nil(action.pagination.default_limit) ->
        {:error, :no_default_limit}

      true ->
        :ok
    end
  end

  @doc """
  Prose for a `check/3` failure, naming the resource, the action and the fix.

  `context` opens the message with why this resource was asked at all — a
  dropdown pointing at it reads differently from its own list page, and the
  reader is usually looking at neither file.
  """
  def message(resource, _action_name, :missing_extension, context) do
    """
    #{context}

    #{inspect(resource)} does not carry the AshQuick extension, so nothing has \
    declared which of its actions a search runs through.

    Add it to the resource:

        use Ash.Resource,
          extensions: [AshQuick, ...]
    """
  end

  def message(resource, action_name, reason, context) do
    """
    #{context}

    #{detail(resource, action_name, reason)}

    A lookup action has to exist, accept the search argument every caller \
    passes it — including the `nil` they pass when there is nothing to search \
    for — and paginate with a default limit: the list reads its answer through \
    `Ash.Query.page/2`, and the dropdowns open on a page they set no limit of \
    their own on and read `.results` off it.

        read #{inspect(action_name)} do
          argument :search, :string

          prepare SomeSearchPreparation

          pagination do
            keyset? true
            offset? true
            default_limit 20
            countable :by_default
          end
        end

    A resource whose searchable read is named or shaped differently says so \
    instead:

        ash_quick do
          lookup do
            action :the_action
            search_argument :the_argument
          end
        end
    """
  end

  defp detail(resource, action_name, :missing_action) do
    "#{inspect(resource)} defines no #{inspect(action_name)} action."
  end

  defp detail(resource, action_name, {:not_a_read, type}) do
    "#{inspect(resource)}'s #{inspect(action_name)} is a #{type} action, not a read."
  end

  defp detail(resource, action_name, {:missing_argument, argument}) do
    "#{inspect(resource)}'s #{inspect(action_name)} action takes no #{inspect(argument)} argument."
  end

  defp detail(resource, action_name, {:required_argument, argument}) do
    "#{inspect(resource)}'s #{inspect(action_name)} action requires its #{inspect(argument)} " <>
      "argument, but an unsearched read passes `nil` for it."
  end

  defp detail(resource, action_name, :no_pagination) do
    "#{inspect(resource)}'s #{inspect(action_name)} action declares no pagination."
  end

  defp detail(resource, action_name, :no_default_limit) do
    "#{inspect(resource)}'s #{inspect(action_name)} action paginates without a `default_limit`, " <>
      "but a dropdown opens on a page it sets no limit of its own on."
  end
end
