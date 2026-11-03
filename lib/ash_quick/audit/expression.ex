defmodule AshQuick.Audit.Expression do
  @moduledoc false
  # The text an audit entry keeps for an expression a change asked the data
  # layer to work out — `count + 1` — next to the `from` and `to` it came to.
  #
  # Text rather than the expression: nothing will ever evaluate a stored one
  # again, and the struct is Ash's internals, holding modules and shapes that
  # change between versions. What a timeline needs is the intent, rendered by
  # Ash's own `Inspect` implementations.
  #
  # The expression is kept as `AshQuick.Audit.Change` first sees it, after the
  # action's own changes (`remember/1`). By the time the entry is written Ash has
  # wrapped it, on the way to the data layer, in a check for each of the
  # attribute's constraints and a required check, which together can bury
  # `count + 1` under a dozen lines. What is already there when it is kept is
  # the attribute type's own cast, undone here for a string, and the type an
  # `^atomic_ref(...)` was read as.
  #
  # Ash has also put every `^arg(...)`, `^actor(...)` and `^atomic_ref(...)` in
  # by then, as a literal, so the text holds the values the caller passed. A
  # secret among them is replaced before rendering (see `secrets/3`).

  alias Ash.Query.Function.Fragment
  alias Ash.Query.Function.If
  alias Ash.Query.Function.StringTrim
  alias Ash.Query.Function.Type
  alias Ash.Query.Operator.Eq

  defmodule Redacted do
    @moduledoc false
    # Stands in for a secret inside an expression and renders as the marker the
    # rest of the entry uses, unquoted, so it does not read as a string literal.
    defstruct []

    defimpl Inspect do
      def inspect(_redacted, _opts), do: "**redacted**"
    end
  end

  defmodule Grouped do
    @moduledoc false
    # An operator's operand that is itself an operator. Ash prints `left op
    # right` without parentheses, so `(count + 1) * 2` would read
    # `count + 1 * 2`, a different formula.
    defstruct [:expression]

    defimpl Inspect do
      import Inspect.Algebra

      def inspect(%{expression: expression}, opts),
        do: concat(["(", to_doc(expression, opts), ")"])
    end
  end

  @redacted "**redacted**"

  # A top-level context key holding a map, which `AshQuick.Audit.Row` never
  # copies into the row's `context`.
  @context :ash_quick_audit_expressions

  @doc """
  Keeps the expressions `changeset.atomics` holds now, for `expression/2`.
  """
  def remember(%Ash.Changeset{} = changeset) do
    case for {name, value} <- changeset.atomics,
             Ash.Expr.expr?(value),
             into: %{},
             do: {name, value} do
      expressions when expressions == %{} -> changeset
      expressions -> Ash.Changeset.put_context(changeset, @context, expressions)
    end
  end

  @doc """
  The expression `remember/1` kept for `name`, or, for one a later change set,
  what the changeset holds now.
  """
  def expression(%Ash.Changeset{} = changeset, name) do
    case changeset.context do
      %{@context => %{^name => expression}} -> hydrate(expression, changeset.resource)
      _context -> Keyword.fetch!(changeset.atomics, name)
    end
  end

  # What is kept is still calls by name — `if`, `string_trim` — as written.
  # Ash resolves them into the functions they name before the data layer sees
  # them, and so does this, so a wrapper is recognised by what it is.
  defp hydrate(expression, resource) do
    case Ash.Filter.hydrate_refs(expression, %{resource: resource, public?: false}) do
      {:ok, hydrated} -> hydrated
      {:error, _error} -> expression
    end
  end

  @doc """
  The changeset without what `remember/1` kept, which can hold a secret the way
  `atomics` can.
  """
  def forget(%Ash.Changeset{} = changeset),
    do: %{changeset | context: Map.delete(changeset.context, @context)}

  @doc """
  What may not appear in a rendered expression: the values of the sensitive
  arguments the write was given (`given`), and those of the sensitive attributes
  on either side of it (`held`), which `^atomic_ref(...)` or a pinned record
  field can carry into another attribute's expression.

  `attributes` and `arguments` are the names `AshQuick.Audit.Change` redacts.
  Read off the changeset before it is redacted.
  """
  def secrets(%Ash.Changeset{} = changeset, attributes, arguments) do
    atomics = Map.new(changeset.atomics)

    given =
      for name <- arguments,
          value = Map.get(changeset.arguments, name),
          not is_nil(value),
          do: value

    held =
      for name <- attributes,
          source <- [changeset.data, changeset.attributes, atomics],
          value = Map.get(source, name),
          not is_nil(value),
          not is_struct(value, Ash.NotLoaded),
          not Ash.Expr.expr?(value),
          do: value

    %{given: given, held: held}
  end

  @doc """
  The expression as one line, without the wrappers Ash added, and with
  `secrets` replaced. `attribute` is the one it sets; `attributes` all of the
  resource's.
  """
  def render(expression, attribute, attributes, secrets) do
    text =
      expression
      |> uncast(attribute)
      |> hide(attributes, secrets)
      |> group()
      |> inspect(limit: :infinity, printable_limit: :infinity)
      # Ash's `if` and `cond` force line breaks; a string literal holding one
      # renders it as `\n`, so only layout is joined here.
      |> String.replace(~r/\n\s*/, " ")

    # For a secret somewhere the walk does not reach — inside an `exists`, or an
    # aggregate's own filter — the whole expression goes.
    if leaks?(text, secrets), do: @redacted, else: text
  end

  # `Ash.Type.String.cast_atomic/2`: `string_trim/1` unless `trim?: false`, then
  # nil for an empty result unless `allow_empty?: true` — undone in the reverse
  # order, and only the layers the attribute's constraints say Ash added.
  defp uncast(expression, %{type: type, constraints: constraints}) do
    if string?(type) do
      case {Keyword.get(constraints, :allow_empty?, false), expression} do
        {false, %If{arguments: [%Eq{left: trimmed, right: ""}, nil, trimmed]}} ->
          untrim(trimmed, constraints)

        {false, expression} ->
          expression

        {true, expression} ->
          untrim(expression, constraints)
      end
    else
      expression
    end
  end

  defp untrim(%StringTrim{arguments: [expression]} = trimmed, constraints) do
    if Keyword.get(constraints, :trim?, true), do: expression, else: trimmed
  end

  defp untrim(expression, _constraints), do: expression

  defp string?(Ash.Type.String), do: true

  defp string?(type) do
    Ash.Type.NewType.new_type?(type) and Ash.Type.NewType.subtype_of(type) == Ash.Type.String
  end

  # A literal is everything that is not an expression node. Once a sensitive
  # argument was given, no literal can be told apart from one derived from it —
  # Ash folds an all-literal part such as `1 + ^arg(:bonus)` into one value on
  # the way to the data layer, and a change can do the same sum itself — so all
  # of them go. Otherwise only one equal to a held secret, or a string
  # containing one, which is what a pinned secret looks like after a `<>` was
  # folded.
  defp hide(expression, attributes, secrets) do
    Ash.Filter.map(expression, fn
      %Fragment{} = fragment ->
        {:halt, hide_fragment(fragment, attributes, secrets)}

      %Type{arguments: [value, type, constraints]} = cast ->
        if read_as_attribute?(attributes, type, constraints),
          do: {:halt, hide(value, attributes, secrets)},
          else: cast

      # Walked item by item, as the arguments of an unresolved call are a list.
      list when is_list(list) ->
        list

      node ->
        if Ash.Expr.expr?(node), do: node, else: {:halt, hide_value(node, secrets)}
    end)
  end

  # Every operand that is an operator is parenthesised, whatever the precedence:
  # `(count + 1) + 1` says no less than `count + 1 + 1`, and working out which
  # pairs could go would be a second copy of Ash's grammar to keep right. `and`
  # and `or` parenthesise their own operands.
  defp group(%{__operator__?: true, left: left, right: right} = operator),
    do: %{operator | left: operand(left), right: operand(right)}

  defp group(%Ash.Query.Call{operator?: true, args: args} = call),
    do: %{call | args: Enum.map(args, &operand/1)}

  defp group(%Ash.Query.Call{args: args} = call), do: %{call | args: group(args)}

  defp group(%Fragment{} = fragment) do
    extra =
      case fragment.extra do
        %{original: [sql | values]} = extra -> %{extra | original: [sql | group(values)]}
        extra -> extra
      end

    %{fragment | arguments: group(fragment.arguments), extra: extra}
  end

  defp group(%{__function__?: true, arguments: arguments} = function),
    do: %{function | arguments: group(arguments)}

  defp group(%Ash.Query.BooleanExpression{left: left, right: right} = expression),
    do: %{expression | left: group(left), right: group(right)}

  defp group(%Ash.Query.Not{expression: expression} = negated),
    do: %{negated | expression: group(expression)}

  defp group(list) when is_list(list), do: Enum.map(list, &group/1)
  defp group({key, value}) when is_atom(key), do: {key, group(value)}
  defp group(other), do: other

  defp operand(%{__operator__?: true} = operator), do: %Grouped{expression: group(operator)}
  defp operand(%Ash.Query.Call{operator?: true} = call), do: %Grouped{expression: group(call)}
  defp operand(other), do: group(other)

  # How Ash reads an `^atomic_ref(...)`: the other attribute's value, cast to
  # its type with all of its constraints — which no expression written by hand
  # spells out down to the defaults.
  defp read_as_attribute?(attributes, type, constraints),
    do: Enum.any?(attributes, &(&1.type == type and &1.constraints == constraints))

  # A fragment renders from the arguments it was written with (`extra.original`)
  # rather than the parsed ones `Ash.Filter.map/2` walks. Its SQL is the
  # developer's, never a value.
  defp hide_fragment(%Fragment{} = fragment, attributes, secrets) do
    arguments =
      Enum.map(fragment.arguments, fn
        {:raw, _sql} = raw -> raw
        {tag, value} -> {tag, hide(value, attributes, secrets)}
      end)

    extra =
      case fragment.extra do
        %{original: [sql | values]} = extra ->
          %{extra | original: [sql | Enum.map(values, &hide(&1, attributes, secrets))]}

        extra ->
          extra
      end

    %{fragment | arguments: arguments, extra: extra}
  end

  # An atom other than a boolean is a name — a map key, a type, an option — and
  # nil is the absence of a value; neither is a secret.
  defp hide_value(value, _secrets) when is_nil(value), do: value
  defp hide_value(value, _secrets) when is_atom(value) and not is_boolean(value), do: value
  defp hide_value(_value, %{given: [_ | _]}), do: %Redacted{}

  defp hide_value(value, %{held: held}) do
    if Enum.any?(held, &contains?(value, &1)), do: %Redacted{}, else: value
  end

  # A literal equal to a secret is redacted whatever its length. Finding one
  # *inside* a longer text is another matter: a short secret turns up there by
  # chance — a pin of "nt" inside `count` — and would cost every expression on
  # the resource its text for nothing. Below this length only an exact match
  # counts.
  @shortest_found_inside 4

  defp contains?(value, secret) when is_binary(value) and is_binary(secret),
    do: value == secret or (findable?(secret) and String.contains?(value, secret))

  defp contains?(value, secret), do: value == secret

  defp leaks?(text, %{given: given, held: held}) do
    Enum.any?(given ++ held, fn secret ->
      printed = printed(secret)
      findable?(printed) and String.contains?(text, printed)
    end)
  end

  defp findable?(secret),
    do: is_binary(secret) and String.length(secret) >= @shortest_found_inside

  defp printed(secret) when is_binary(secret), do: secret
  defp printed(secret) when is_number(secret), do: to_string(secret)
  defp printed(%Decimal{} = secret), do: Decimal.to_string(secret)
  defp printed(_secret), do: nil
end
