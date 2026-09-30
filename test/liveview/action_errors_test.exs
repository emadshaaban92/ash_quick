defmodule AshQuick.LiveView.ActionErrorsTest do
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.ActionErrors

  describe "user_facing_message/1" do
    test "passes an already-human string through untouched" do
      assert ActionErrors.user_facing_message("Pick a reason.") == "Pick a reason."
    end

    # This asserts the whole string rather than `=~ "is required"`. The dump
    # this module exists to prevent *contains* the useful fragment — it is the
    # bread crumbs, the class header and the "Value: nil" wrapped around it that
    # make it unreadable — so a `=~` here passes on exactly the output we are
    # trying to keep out of the UI.
    test "renders a field-relative validation error as a sentence naming the field" do
      error =
        Ash.Error.Invalid.exception(
          errors: [
            Ash.Error.Changes.InvalidAttribute.exception(field: :name, message: "is required")
          ]
        )

      assert ActionErrors.user_facing_message(error) == "Name is required"
    end

    # Messages written for a specific situation are already sentences; putting
    # the field in front of one ("Tracking number Transfer not found for...")
    # would garble it.
    test "leaves a message that is already a sentence alone" do
      error =
        Ash.Error.Invalid.exception(
          errors: [
            Ash.Error.Changes.InvalidAttribute.exception(
              field: :tracking_number,
              message: "Transfer not found for tracking number: TN123"
            )
          ]
        )

      assert ActionErrors.user_facing_message(error) ==
               "Transfer not found for tracking number: TN123"
    end

    test "renders one line per thing that was wrong, without repeating itself" do
      error =
        Ash.Error.Invalid.exception(
          errors: [
            Ash.Error.Changes.Required.exception(field: :name, type: :attribute),
            Ash.Error.Changes.Required.exception(field: :code, type: :attribute),
            Ash.Error.Changes.Required.exception(field: :code, type: :attribute)
          ]
        )

      assert ActionErrors.user_facing_message(error) == "Name is required\nCode is required"
    end

    test "interpolates the vars a message carries rather than showing the template" do
      error =
        Ash.Error.Invalid.exception(
          errors: [
            Ash.Error.Changes.InvalidAttribute.exception(
              field: :quantity,
              message: "must be less than %{max}",
              vars: [max: 10]
            )
          ]
        )

      assert ActionErrors.user_facing_message(error) == "Quantity must be less than 10"
    end

    # An `:invalid` class is not a promise that the user did something wrong —
    # Ash puts framework failures like this one in it too, and they have no
    # message worth showing.
    test "reduces an internal error wearing an :invalid class to the generic message" do
      error =
        Ash.Error.Invalid.exception(
          errors: [Ash.Error.Invalid.TenantRequired.exception(resource: SomeResource)]
        )

      message = ActionErrors.user_facing_message(error)

      assert message == ActionErrors.generic_message()
      refute message =~ "Tenant"
      refute message =~ "Ash.Error"
    end

    # `NotFound` renders one sentence per primary-key field, and most carry no
    # primary key at all — so routing it through the sub-error render produces
    # nothing, which is indistinguishable from a bug and would report a record
    # someone deleted to Tower.
    test "reduces a missing record to the friendly not-found message" do
      error =
        Ash.Error.Invalid.exception(
          errors: [Ash.Error.Query.NotFound.exception(resource: SomeResource)]
        )

      message = ActionErrors.user_facing_message(error)

      assert message == ActionErrors.not_found_message()
      refute message == ActionErrors.generic_message()
    end

    # A `NotFound` can ride alongside a real validation error — pick a
    # since-deleted related record AND leave a required field blank. The
    # validation message is what the user needs to act on, so it wins; the
    # not-found copy must not swallow it.
    test "shows the validation message when a missing record rides alongside one" do
      error =
        Ash.Error.Invalid.exception(
          errors: [
            Ash.Error.Query.NotFound.exception(resource: SomeResource),
            Ash.Error.Changes.InvalidAttribute.exception(
              field: :quantity,
              message: "must be greater than %{min}",
              vars: [min: 0]
            )
          ]
        )

      message = ActionErrors.user_facing_message(error)

      assert message == "Quantity must be greater than 0"
      refute message == ActionErrors.not_found_message()
    end

    # A message whose first character has no uppercase form — a digit here, but
    # equally any uncased script — is not a sentence someone wrote for this
    # situation, so it still needs its field in front.
    test "names the field even when an interpolated message starts with a digit" do
      error =
        Ash.Error.Invalid.exception(
          errors: [
            Ash.Error.Changes.InvalidAttribute.exception(
              field: :quantity,
              message: "%{max} is the most you can order",
              vars: [max: 10]
            )
          ]
        )

      assert ActionErrors.user_facing_message(error) ==
               "Quantity 10 is the most you can order"
    end

    # What `validate match(:code, ~r/^\d+$/), message: "must be digits"` raises:
    # the Regex rides along as a var whatever the message says, and has no
    # `String.Chars`. Stringifying every var took the LiveView down with it, so
    # the person never saw the message the validation was written to show.
    test "renders a match/2 message without touching the regex it never names" do
      error =
        Ash.Error.Invalid.exception(
          errors: [
            Ash.Error.Changes.InvalidAttribute.exception(
              field: :code,
              message: "must be digits",
              vars: [field: :code, match: ~r/^\d+$/]
            )
          ]
        )

      assert ActionErrors.user_facing_message(error) == "Code must be digits"
    end

    # And when the message does name it, it is shown the way Ash itself would
    # show it rather than raising.
    test "renders a var with no String.Chars through inspect when the message names it" do
      error =
        Ash.Error.Invalid.exception(
          errors: [
            Ash.Error.Changes.InvalidAttribute.exception(
              field: :code,
              message: "must match %{match}",
              vars: [field: :code, match: ~r/^\d+$/]
            )
          ]
        )

      assert ActionErrors.user_facing_message(error) == ~S"Code must match ~r/^\d+$/"
    end

    test "reduces a stale-record conflict to the friendly reload message" do
      error = Ash.Error.Invalid.exception(errors: [%Ash.Error.Changes.StaleRecord{}])

      assert ActionErrors.user_facing_message(error) == ActionErrors.stale_message()
    end

    test "reduces an authorization failure to the friendly forbidden message" do
      error = Ash.Error.Forbidden.exception(errors: [])

      message = ActionErrors.user_facing_message(error)

      assert message == ActionErrors.forbidden_message()
      refute message =~ "Ash.Error"
      refute message =~ "%"
    end

    # A validation is free to refuse a value without saying why —
    # `add_error(field: :price)` is one — and `to_form_error/1` then renders
    # nothing at all. Which field was refused is the whole of what the error
    # knows, and it is still something a person can act on; answering a bad
    # input with "something went wrong on our end" sends them looking in the
    # wrong place, and reports their typo as our bug.
    test "names the field when an input error carries no message of its own" do
      error =
        Ash.Error.Invalid.exception(
          errors: [Ash.Error.Changes.InvalidAttribute.exception(field: :price)]
        )

      message = ActionErrors.user_facing_message(error)

      assert message == "Price is invalid."
      refute message == ActionErrors.generic_message()
    end

    # The same for an error that refuses a combination rather than one field —
    # `InvalidChanges` carries `:fields` where `InvalidAttribute` carries
    # `:field`.
    test "names every field when a message-less error refuses a combination" do
      error =
        Ash.Error.Invalid.exception(
          errors: [Ash.Error.Changes.InvalidChanges.exception(fields: [:starts_at, :ends_at])]
        )

      assert ActionErrors.user_facing_message(error) ==
               "Starts At is invalid.\nEnds At is invalid."
    end

    # The fallback above is for errors that describe *input*. It must not reach
    # a framework failure that happens to carry a field, and it must not take
    # the not-found path's place — both of those still answer with their own
    # copy.
    test "the field fallback does not swallow the not-found message" do
      error =
        Ash.Error.Invalid.exception(
          errors: [Ash.Error.Query.NotFound.exception(resource: SomeResource)]
        )

      assert ActionErrors.user_facing_message(error) == ActionErrors.not_found_message()
    end

    test "never leaks an unexpected error struct — returns the generic message" do
      # An Unknown-class error (or any raw exception) must not reach the user.
      message = ActionErrors.user_facing_message(%RuntimeError{message: "secret internal detail"})

      assert message == ActionErrors.generic_message()
      refute message =~ "secret internal detail"
      refute message =~ "RuntimeError"
    end
  end

  describe "interpolate/2" do
    test "leaves a var the message never names alone, whatever it is" do
      assert ActionErrors.interpolate("must be digits", match: ~r/x/, pid: self()) ==
               "must be digits"
    end

    test "renders a named var with String.Chars through to_string" do
      assert ActionErrors.interpolate("between %{min} and %{max}", min: 5, max: :fifteen) ==
               "between 5 and fifteen"
    end

    test "renders a named var with no String.Chars through inspect" do
      assert ActionErrors.interpolate("must match %{match}", match: ~r/^\d+$/) ==
               ~S"must match ~r/^\d+$/"

      assert ActionErrors.interpolate("got %{value}", value: %{a: 1}) == "got %{a: 1}"
    end

    # A list has `String.Chars`, but only converts when it is chardata.
    test "renders a named list that is not chardata through inspect" do
      assert ActionErrors.interpolate("one of %{one_of}", one_of: [:a, :b]) == "one of [:a, :b]"
      assert ActionErrors.interpolate("like %{example}", example: ~c"abc") == "like abc"
    end

    test "takes nil vars as none" do
      assert ActionErrors.interpolate("is required", nil) == "is required"
    end
  end
end
