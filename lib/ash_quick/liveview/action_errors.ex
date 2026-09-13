defmodule AshQuick.LiveView.ActionErrors do
  @moduledoc false
  # Shared helpers for turning Ash action errors into user-facing messages in the
  # QuickView list/detail action handlers (and any host-app LiveView that runs an
  # Ash action and needs to show the outcome).
  #
  # `user_facing_message/1` is the single choke point: expected, actionable
  # failures (validation, optimistic-lock conflicts, authorization) keep their
  # helpful text; anything unexpected (framework/unknown errors, raw exceptions)
  # is reported to Tower (which fans out to the configured reporters) and reduced
  # to a generic sentence so internal structs never reach the user.

  @stale_message "This record changed since you opened it — reload to see the latest, then try again."
  @forbidden_message "You don't have permission to do that."
  @not_found_message "That record no longer exists — it may have been deleted since you opened this page."
  @generic_message "Something went wrong on our end. Please try again, or contact support if it keeps happening."

  @doc "A friendly message for an optimistic-lock (`StaleRecord`) conflict."
  def stale_message, do: @stale_message

  @doc "A friendly message for an authorization (`Forbidden`) failure."
  def forbidden_message, do: @forbidden_message

  @doc "A friendly message for a record that isn't there."
  def not_found_message, do: @not_found_message

  @doc "A friendly, non-leaking message for an unexpected failure."
  def generic_message, do: @generic_message

  @doc """
  Whether `error` (or any error it wraps) is an `Ash.Error.Changes.StaleRecord` —
  the optimistic-lock conflict raised when the record changed since it was loaded.
  """
  def stale_record?(error), do: wraps_error?(error, Ash.Error.Changes.StaleRecord)

  @doc """
  Whether `error` is (or wraps) an `Ash.Error.Forbidden` — an authorization
  failure raised when the actor is not allowed to run the action.
  """
  def forbidden?(error), do: wraps_error?(error, Ash.Error.Forbidden)

  @doc """
  Whether `error` is (or wraps) an `Ash.Error.Query.NotFound` — the record the
  action was aimed at isn't there.
  """
  def not_found?(error), do: wraps_error?(error, Ash.Error.Query.NotFound)

  # Total: any term (atom, tuple, plain map, list, struct) answers true/false
  # without raising, so an unexpected `{:error, term}` falls through to the
  # generic/report path instead of crashing the caller's error handler.
  defp wraps_error?(error, module) do
    error
    |> List.wrap()
    |> Enum.any?(fn
      %{errors: errors} = err when is_list(errors) ->
        is_struct(err, module) or Enum.any?(errors, &is_struct(&1, module))

      other ->
        is_struct(other, module)
    end)
  end

  @doc """
  Turns any action error into a safe, human-readable message suitable for a
  flash or an error banner.

  - already-human strings pass through untouched;
  - stale-record conflicts, authorization failures and missing records get their
    friendly copy;
  - `Ash.Error.Invalid` is rendered from its sub-errors, one sentence per thing
    that was wrong with the input;
  - everything else is reported to Tower and reduced to `generic_message/0`.
  """
  def user_facing_message(message) when is_binary(message), do: message

  def user_facing_message(error) do
    cond do
      stale_record?(error) -> @stale_message
      forbidden?(error) -> @forbidden_message
      match?(%Ash.Error.Invalid{}, error) -> invalid_message(error)
      not_found?(error) -> @not_found_message
      true -> report_unexpected(error)
    end
  end

  # `Ash.Error.Invalid` is the class Ash puts bad input in, but it is a
  # container, and `Ash.Error.error_descriptions/1` renders the container: the
  # class header, the bread crumbs, and a `Value: nil` line per sub-error. That
  # is a debug dump, not something to put in front of an operator holding a
  # phone. Render the sub-errors instead, through the same protocol AshPhoenix
  # uses to place messages next to form fields.
  #
  # The protocol is implemented only for the errors that describe bad *input*.
  # Anything else wearing an `:invalid` class (a timeout, a missing tenant) is
  # our bug rather than the user's, so it takes the reported/generic path.
  #
  # `NotFound` implements the protocol, so it lands in `input_errors`, but it
  # renders one sentence per primary-key field and so renders *nothing* when it
  # carries no primary key — which is most of them. When it is the only thing
  # here it contributes no message, and we answer with the friendly not-found
  # copy rather than reporting a deleted record to Tower. But when a real
  # validation error rides alongside it, that message is what the user needs to
  # see and act on, so it wins — checking `not_found?` first would drop it.
  defp invalid_message(%Ash.Error.Invalid{errors: errors} = error) do
    {input_errors, ours} = Enum.split_with(List.wrap(errors), &input_error?/1)
    messages = input_errors |> Enum.flat_map(&error_sentences/1) |> Enum.uniq()

    cond do
      messages != [] ->
        # Report our own errors even when a real validation message rides
        # alongside one and is what the user ends up seeing.
        if ours != [], do: report_error(error)
        Enum.join(messages, "\n")

      not_found?(error) ->
        @not_found_message

      true ->
        report_error(error)
        @generic_message
    end
  end

  defp input_error?(error), do: not is_nil(AshPhoenix.FormData.Error.impl_for(error))

  defp error_sentences(error) do
    error
    |> AshPhoenix.FormData.Error.to_form_error()
    |> List.wrap()
    |> Enum.map(&sentence/1)
    |> Enum.reject(&(&1 == ""))
  end

  # `to_form_error/1` yields the fragment a form shows against an input, which
  # has to stand on its own here. Ash's built-in messages are lowercase and
  # field-relative ("is required"), so they get the field name in front; a
  # message starting with a capital was written for this exact situation
  # ("Transfer not found for tracking number: TN123") and prefixing it would
  # only garble it.
  defp sentence({field, message, vars}) when is_binary(message) do
    message = replace_vars(message, vars)

    cond do
      message == "" -> ""
      field in [nil, :_form] -> message
      standalone_sentence?(message) -> message
      true -> "#{AshQuick.LiveView.Utils.humanize(field)} #{message}"
    end
  end

  defp sentence(_), do: ""

  # An uppercase *letter*, specifically. Testing `upcase(first) == first` would
  # also read a digit or an uncased script (Arabic) as a sentence, dropping the
  # field name off a message that needed it.
  defp standalone_sentence?(message), do: message =~ ~r/^\p{Lu}/u

  defp replace_vars(message, vars) do
    Enum.reduce(vars || [], message, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp report_unexpected(error) do
    report_error(error)
    @generic_message
  end

  defp report_error(error) when is_exception(error),
    do: Tower.report_exception(error, current_stacktrace())

  defp report_error(error), do: Tower.report(:error, error, current_stacktrace())

  defp current_stacktrace do
    {:current_stacktrace, trace} = Process.info(self(), :current_stacktrace)
    trace
  end
end
