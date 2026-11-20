if Code.ensure_loaded?(Igniter) do
  defmodule AshQuick.Igniter.LiveSessions do
    @moduledoc false
    # The router's live sessions as `mix ash_quick.install` and
    # `mix ash_quick.gen.quick_view` read them: which run AshQuick's mount,
    # which have the route gate, and which serve QuickViews. A stage is matched
    # by the module it names, however the router spells it: written out, as
    # `{Module, :stage}`, or through an `alias` in scope where it is used.

    alias Igniter.Code.Common
    alias Igniter.Code.Function
    alias Igniter.Code.List, as: CodeList
    alias Igniter.Code.Tuple
    alias Sourceror.Zipper

    @macros [:live_session, :ash_authentication_live_session]

    @doc "Whether `zipper` is at a live session, Phoenix's or AshAuthentication's."
    def live_session?(zipper) do
      Enum.any?(@macros, &Function.function_call?(zipper, &1, [2, 3]))
    end

    @doc "The live session's `on_mount` value, when it names one."
    def stages(session) do
      with {:ok, opts} <- Function.move_to_nth_argument(session, 1),
           {:ok, stages} <- Igniter.Code.Keyword.get_key(opts, :on_mount) do
        {:ok, Common.maybe_move_to_single_child_block(stages)}
      else
        _other -> :error
      end
    end

    @doc """
    How the session's `on_mount` is written: `:list` (a literal list, which a
    stage can be appended to), `:stage` (one module or `{module, arg}`),
    `:none`, or `:unknown` (a module attribute, a variable, a call: nothing the
    stages can be read out of).
    """
    def shape(session) do
      case stages(session) do
        :error -> :none
        {:ok, stages} -> stages_shape(stages)
      end
    end

    defp stages_shape(stages) do
      cond do
        CodeList.list?(stages) -> :list
        stage_shaped?(stages) -> :stage
        true -> :unknown
      end
    end

    defp stage_shaped?(stage) do
      case Zipper.node(stage) do
        {:__aliases__, _meta, _parts} -> true
        atom when is_atom(atom) -> true
        _other -> Tuple.tuple?(stage)
      end
    end

    @doc "Whether the session's `on_mount` names `module` as a stage."
    def runs?(session, module) do
      live_session?(session) and
        case stages(session) do
          {:ok, stages} -> names?(stages, module)
          :error -> false
        end
    end

    @doc "Whether the session routes a QuickView with `quick_view/2,3`."
    def serves_quick_views?(session) do
      {_ast, found?} =
        session
        |> Zipper.node()
        |> Macro.prewalk(false, fn
          {:quick_view, _meta, args} = node, _found
          when is_list(args) and length(args) in [2, 3] ->
            {node, true}

          node, found ->
            {node, found}
        end)

      found?
    end

    @doc "The session's name as written, for a message."
    def name(session) do
      case Function.move_to_nth_argument(session, 0) do
        {:ok, name} -> name |> Zipper.node() |> Sourceror.to_string()
        :error -> "a live session"
      end
    end

    @doc "The session's `on_mount` as written, for a message."
    def stages_source(session) do
      case stages(session) do
        {:ok, stages} -> stages |> Zipper.node() |> Sourceror.to_string()
        :error -> "nothing"
      end
    end

    defp names?(stages, module) do
      aliases = aliases_in_scope(stages)

      if CodeList.list?(stages) do
        not is_nil(CodeList.find_list_item_index(stages, &stage?(&1, module, aliases)))
      else
        stage?(stages, module, aliases)
      end
    end

    defp stage?(stage, module, aliases) do
      stage = Common.maybe_move_to_single_child_block(stage)

      if Tuple.tuple?(stage) do
        case Tuple.tuple_elem(stage, 0) do
          {:ok, first} -> module?(first, module, aliases)
          :error -> false
        end
      else
        module?(stage, module, aliases)
      end
    end

    # Resolved against the router's own `alias` forms rather than through
    # Igniter's environment, which stops at the first `use` it cannot expand
    # (a router's `use MyAppWeb, :router`) and hands the short name back.
    # Compared as text, so reading a router creates no atoms.
    defp module?(zipper, module, aliases) do
      case zipper |> Common.maybe_move_to_single_child_block() |> Zipper.node() do
        {:__aliases__, _meta, parts} ->
          Enum.all?(parts, &is_atom/1) and dotted(expand(parts, aliases)) == inspect(module)

        atom when is_atom(atom) ->
          atom == module

        _other ->
          false
      end
    end

    defp expand([first | rest] = parts, aliases) do
      case Map.fetch(aliases, first) do
        {:ok, full} -> full ++ rest
        :error -> parts
      end
    end

    defp dotted(parts), do: Enum.map_join(parts, ".", &Atom.to_string/1)

    # The aliases in scope where `zipper` is: every `alias` written before it
    # in each block enclosing it, the innermost winning, as short name to the
    # full module's segments. `alias A.B`, `alias A.B, as: C` and
    # `alias A.{B, C.D}`; one whose module is not written out in full, such as
    # `alias __MODULE__.X`, is left out.
    defp aliases_in_scope(zipper), do: aliases_in_scope(zipper, %{})

    defp aliases_in_scope(zipper, acc) do
      acc = zipper |> preceding_siblings() |> Enum.reduce(acc, &add_alias_node/2)

      case Zipper.up(zipper) do
        nil -> acc
        parent -> aliases_in_scope(parent, acc)
      end
    end

    # Nearest first, so an inner alias is seen before an outer one.
    defp preceding_siblings(zipper) do
      zipper
      |> Stream.unfold(fn zipper ->
        case Zipper.left(zipper) do
          nil -> nil
          left -> {Zipper.node(left), left}
        end
      end)
      |> Enum.to_list()
    end

    defp add_alias_node({:alias, _meta, [target | opts]}, acc), do: add_alias(acc, target, opts)
    defp add_alias_node(_node, acc), do: acc

    defp add_alias(acc, {{:., _, [{:__aliases__, _, base}, :{}]}, _, children}, _opts) do
      Enum.reduce(children, acc, fn
        {:__aliases__, _, parts}, acc -> put_alias(acc, List.last(parts), base ++ parts)
        _other, acc -> acc
      end)
    end

    defp add_alias(acc, {:__aliases__, _, parts}, opts) do
      case as(opts) do
        {:__aliases__, _, [short]} -> put_alias(acc, short, parts)
        _none -> put_alias(acc, List.last(parts), parts)
      end
    end

    defp add_alias(acc, _target, _opts), do: acc

    defp put_alias(acc, short, parts) do
      if is_atom(short) and Enum.all?(parts, &is_atom/1),
        do: Map.put_new(acc, short, parts),
        else: acc
    end

    defp as([opts]) when is_list(opts) do
      Enum.find_value(opts, fn
        {{:__block__, _, [:as]}, value} -> value
        {:as, value} -> value
        _other -> nil
      end)
    end

    defp as(_opts), do: nil
  end
end
