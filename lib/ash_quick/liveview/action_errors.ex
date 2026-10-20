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

  # The fixed sentences are AshQuick's own, so they go through its catalogue in
  # the locale of the process that flashes them.
  use Gettext, backend: AshQuick.Gettext

  @doc "A friendly message for an optimistic-lock (`StaleRecord`) conflict."
  def stale_message,
    do:
      gettext(
        "This record changed since you opened it — reload to see the latest, then try again."
      )

  @doc "A friendly message for an authorization (`Forbidden`) failure."
  def forbidden_message, do: gettext("You don't have permission to do that.")

  @doc """
  The message for the authorization failure `error` describes: the
  `error_message` of the policy that refused it, when that policy has one, else
  `forbidden_message/0`.

  The policy's message is a msgid like Ash's own, so it goes through
  `translate/2`. Only that message is read, never the rest of the policy error:
  its breakdown describes the host's policies, and is not for the person
  refused. An `error_message` function that returns an exception of its own
  replaces the policy error, so it has no message here and the fixed sentence is
  shown.
  """
  def forbidden_message(error) do
    case policy_messages(error) do
      [message | _] -> translate(message, [])
      [] -> forbidden_message()
    end
  end

  # A policy's `error_message` arrives as `custom_message` on the
  # `Forbidden.Policy` it raised, inside a `Forbidden` class or on its own. It
  # may be built by a function in the policy, which can also hand back an
  # exception of its own instead; only a message that is a string is said.
  defp policy_messages(error) do
    error
    |> List.wrap()
    |> Enum.flat_map(fn
      %Ash.Error.Forbidden.Policy{custom_message: message}
      when is_binary(message) and message != "" ->
        [message]

      %{errors: errors} when is_list(errors) ->
        policy_messages(errors)

      _other ->
        []
    end)
  end

  @doc "A friendly message for a record that isn't there."
  def not_found_message,
    do:
      gettext(
        "That record no longer exists — it may have been deleted since you opened this page."
      )

  @doc "A friendly, non-leaking message for an unexpected failure."
  def generic_message,
    do:
      gettext(
        "Something went wrong on our end. Please try again, or contact support if it keeps happening."
      )

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
  - stale-record conflicts and missing records get their friendly copy;
  - authorization failures say the refusing policy's `error_message`, or the
    friendly copy when it has none;
  - `Ash.Error.Invalid` is rendered from its sub-errors, one sentence per thing
    that was wrong with the input;
  - everything else is reported to Tower and reduced to `generic_message/0`.
  """
  def user_facing_message(message) when is_binary(message), do: message

  def user_facing_message(error) do
    cond do
      stale_record?(error) -> stale_message()
      forbidden?(error) -> forbidden_message(error)
      match?(%Ash.Error.Invalid{}, error) -> invalid_message(error)
      not_found?(error) -> not_found_message()
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
        not_found_message()

      true ->
        report_error(error)
        generic_message()
    end
  end

  defp input_error?(error), do: not is_nil(AshPhoenix.FormData.Error.impl_for(error))

  defp error_sentences(error) do
    error
    |> AshPhoenix.FormData.Error.to_form_error()
    |> List.wrap()
    |> Enum.map(&sentence/1)
    |> Enum.reject(&(&1 == ""))
    |> case do
      [] -> field_sentences(error)
      sentences -> sentences
    end
  end

  # An input error is free to carry no message of its own — `add_error(field:
  # :price)` is a validation refusing a value and saying nothing about why — and
  # `to_form_error/1` then renders nothing. Which field was refused is still a
  # sentence a person can act on, and without one the error contributes no
  # message at all: `invalid_message/1` finds nothing to show, reports the
  # refusal as our bug, and answers a bad input with `generic_message/0`.
  defp field_sentences(%{field: field}) when not is_nil(field),
    do: [invalid_field_sentence(field)]

  defp field_sentences(%{fields: [_ | _] = fields}),
    do: Enum.map(fields, &invalid_field_sentence/1)

  # A validation returning `{:error, "..."}` names no field, and AshPhoenix
  # renders such an error to nothing at all. Its message is what it says.
  defp field_sentences(%{message: message} = error) when is_binary(message) and message != "",
    do: [translate(message, Map.get(error, :vars))]

  defp field_sentences(_), do: []

  defp invalid_field_sentence(field),
    do: "#{AshQuick.LiveView.Utils.humanize(field)}: is invalid"

  @doc """
  Words the input errors among a form's `errors` that `inputs` (a set of field
  names the form renders) has no input to show, one sentence per line, or `nil`
  when there are none.

  Read from the errors themselves rather than from `AshPhoenix.Form.errors/2`,
  which drops every var with no `String.Chars` — the `%Regex{}` a message
  naming `%{match}` needs. Only the form's own errors are read: one with a path
  belongs to a nested form, which shows it.
  """
  def unplaced_message(errors, inputs) do
    case unplaced_sentences(errors, inputs) do
      [] -> nil
      sentences -> Enum.join(sentences, "\n")
    end
  end

  @doc """
  The sentences `unplaced_message/2` joins, as a list, so a caller can say
  where each belongs before joining them: a sub-form's errors are worded
  against its own inputs, and the person still needs to read which item each
  one is about.
  """
  def unplaced_sentences(errors, inputs) do
    errors
    |> List.wrap()
    |> case do
      [] -> []
      errors -> Ash.Error.to_error_class(errors).errors
    end
    |> Enum.filter(&(input_error?(&1) and Map.get(&1, :path, []) in [nil, []]))
    |> Enum.flat_map(&error_unplaced_sentences(&1, inputs))
    |> Enum.uniq()
  end

  # An error that says nothing has nothing to show under an input either, so it
  # is named by its field wherever that is, as `invalid_message/1` names it.
  defp error_unplaced_sentences(error, inputs) do
    error
    |> AshPhoenix.FormData.Error.to_form_error()
    |> List.wrap()
    |> Enum.filter(fn {_field, message, _vars} -> is_binary(message) and message != "" end)
    |> case do
      [] ->
        field_sentences(error)

      said ->
        said
        |> Enum.reject(fn {field, _message, _vars} -> field in inputs end)
        |> Enum.map(&sentence/1)
        |> Enum.reject(&(&1 == ""))
    end
  end

  # `to_form_error/1` yields the fragment a form shows against an input, which
  # has to stand on its own here, so the field it is against goes in front:
  # "Name: is required". Always, and set off by a colon, because whether a
  # message is a fragment or a whole sentence is up to its author, and nothing
  # in its text says which: a first capital letter is absent from Arabic, and a
  # sentence may open with a digit or a fragment with an acronym. Translated
  # first, so the field goes in front of the message the person reads.
  defp sentence({field, message, vars}) when is_binary(message) do
    message = translate(message, vars)

    cond do
      message == "" -> ""
      field in [nil, :_form] -> message
      true -> "#{AshQuick.LiveView.Utils.humanize(field)}: #{message}"
    end
  end

  defp sentence(_), do: ""

  @doc """
  Renders an error's message through the host's `:error_translator`, the
  function its forms translate field errors with, or through `interpolate/2`
  when none is configured.

  Ash marks its own messages for translation, so a host that copies them into
  its catalogue (`mix ash.gen.gettext --domain errors`) has them translated in
  a flash as well as next to an input.

  A var with no `String.Chars` is handed over already rendered through
  `inspect/1`: a translator interpolating it would raise, as `interpolate/2`
  explains, and take the LiveView down with it.
  """
  def translate(message, vars) when is_binary(message) do
    vars = Enum.map(vars || [], fn {key, value} -> {key, stringifiable_var(value)} end)

    case AshQuick.Config.error_translator() do
      nil -> interpolate(message, vars)
      {mod, fun} -> apply(mod, fun, [{message, vars}])
    end
  end

  @doc """
  An error with each of its vars that has no `String.Chars` rendered through
  `inspect/1`, for a form's `transform_errors`.

  AshPhoenix drops such a var before a form shows its errors, so a message
  naming it (`must match %{match}`) shows its placeholder under the input.
  Rendered here, it shows the value, as the same message does in a flash.
  """
  def renderable_vars(_source, %{vars: vars} = error) when is_list(vars) or is_map(vars),
    do: %{error | vars: Enum.map(vars, fn {key, value} -> {key, stringifiable_var(value)} end)}

  def renderable_vars(_source, error), do: error

  # Left as they are when they render, so a translator still gets the integer
  # `:count` it picks a plural form by.
  defp stringifiable_var(value) when is_list(value), do: var_to_string(value)

  defp stringifiable_var(value),
    do: if(String.Chars.impl_for(value), do: value, else: inspect(value))

  @doc """
  Substitutes an error's `vars` into the `%{key}` placeholders of its message.

  The vars an error carries are not all meant for its message. `validate
  match/2` always carries the `%Regex{}` it tested against, whatever the message
  says, and a Regex has no `String.Chars` — so stringifying every var turns a
  refused input into a crashed LiveView, and the person never sees why. Only the
  vars the message names are rendered, and one with no `String.Chars` is
  rendered through `inspect/1` rather than raising.
  """
  def interpolate(message, vars) when is_binary(message) do
    Enum.reduce(vars || [], message, fn {key, value}, acc ->
      placeholder = "%{#{key}}"

      if String.contains?(acc, placeholder),
        do: String.replace(acc, placeholder, var_to_string(value)),
        else: acc
    end)
  end

  # A list implements `String.Chars` but only converts when it is chardata, so
  # a list of atoms (`one_of: [:a, :b]`) raises through `to_string/1` all the
  # same.
  defp var_to_string(value) when is_list(value) do
    List.to_string(value)
  rescue
    ArgumentError -> inspect(value)
  end

  defp var_to_string(value) do
    if String.Chars.impl_for(value), do: to_string(value), else: inspect(value)
  end

  defp report_unexpected(error) do
    report_error(error)
    generic_message()
  end

  defp report_error(error) do
    stacktrace = current_stacktrace()

    if is_exception(error) do
      Tower.report_exception(error, stacktrace)
    else
      Tower.report(:error, error, stacktrace)
    end

    :ok
  end

  defp current_stacktrace do
    {:current_stacktrace, trace} = Process.info(self(), :current_stacktrace)
    trace
  end
end
