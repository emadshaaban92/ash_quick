defmodule AshQuick.LiveView.BulkForm do
  @moduledoc false
  # The form of a bulk action that takes input: one set of values for every
  # selected row, built before any of them is in hand.
  #
  # Ash builds a changeset for one record, running the action's changes and
  # validations against it as it does. There is no record here, and building
  # over a blank struct would judge the values against a record nobody chose:
  # a validation reading the record answers about an empty one, and a change
  # reading it can raise. So the action is never built. The form is an
  # `AshPhoenix.Form` for the rendering and params it does well, held off its
  # action by an error `prepare_source/1` puts on the changeset — Ash builds
  # nothing over an invalid changeset — and its source is replaced by one that
  # checks the inputs alone, through the same casts and constraints Ash would
  # apply: each argument and accepted attribute cast to its type, and each
  # required one present. What depends on a record is the run's to refuse.

  alias Ash.Error.Changes.Required

  @doc "A blank form for `action` over `resource`."
  def new(resource, action, scope) do
    resource
    |> struct()
    |> build(action.type, action.name,
      as: "form",
      scope: scope,
      actor: actor(scope),
      prepare_source: &hold/1
    )
    |> check_inputs(action)
  end

  @doc "`form` with `params` posted to it."
  def validate(form, params, action) do
    form |> AshPhoenix.Form.validate(params) |> check_inputs(action)
  end

  @doc "Whether the posted inputs are all acceptable."
  def valid?(form), do: form.source.valid?

  @doc "The input the run takes: the action's own inputs, as posted."
  def input(form, resource, action) do
    names = resource |> Ash.Resource.Info.action_inputs(action.name) |> Enum.map(&to_string/1)
    Map.take(form.params || %{}, names)
  end

  defp build(data, :destroy, name, opts), do: AshPhoenix.Form.for_destroy(data, name, opts)
  defp build(data, _update, name, opts), do: AshPhoenix.Form.for_update(data, name, opts)

  defp hold(changeset), do: Ash.Changeset.add_error(changeset, "held: no record to build over")

  defp check_inputs(form, action) do
    params = form.params || %{}

    source =
      form.data
      |> Ash.Changeset.new()
      # `params` is what a field whose value did not cast shows again.
      |> Map.merge(%{
        action: action,
        action_type: action.type,
        domain: form.source.domain,
        params: params
      })
      |> cast_attributes(action, params)
      |> cast_arguments(action, params)

    %{form | source: source, valid?: source.valid?}
  end

  # Left out of the post, an attribute is left as each row has it, so only a
  # posted one is required to hold a value.
  defp cast_attributes(changeset, action, params) do
    action
    |> Map.get(:accept, [])
    |> Enum.reduce(changeset, fn name, changeset ->
      case Map.fetch(params, to_string(name)) do
        {:ok, value} ->
          changeset
          |> Ash.Changeset.change_attribute(name, value)
          |> require_value(name, :attribute)

        :error ->
          changeset
      end
    end)
  end

  defp cast_arguments(changeset, action, params) do
    Enum.reduce(action.arguments, changeset, fn argument, changeset ->
      changeset =
        case Map.fetch(params, to_string(argument.name)) do
          {:ok, value} -> Ash.Changeset.set_argument(changeset, argument.name, value)
          :error -> changeset
        end

      if argument.allow_nil? or not is_nil(argument.default),
        do: changeset,
        else: require_value(changeset, argument.name, :argument)
    end)
  end

  defp require_value(changeset, name, type) do
    allow_nil? =
      case type do
        :attribute -> Ash.Resource.Info.attribute(changeset.resource, name).allow_nil?
        :argument -> true
      end

    cond do
      allow_nil? and type == :attribute -> changeset
      errored?(changeset, name) -> changeset
      not is_nil(value(changeset, name, type)) -> changeset
      true -> Ash.Changeset.add_error(changeset, Required.exception(field: name, type: type))
    end
  end

  defp value(changeset, name, :attribute), do: Ash.Changeset.get_attribute(changeset, name)
  defp value(changeset, name, :argument), do: Ash.Changeset.get_argument(changeset, name)

  # A value that failed to cast already says so; "is required" beside it would
  # describe the cast rather than what was typed.
  defp errored?(changeset, name), do: Enum.any?(changeset.errors, &(Map.get(&1, :field) == name))

  defp actor(scope) do
    case Ash.Scope.ToOpts.get_actor(scope) do
      {:ok, actor} -> actor
      _ -> nil
    end
  end
end
