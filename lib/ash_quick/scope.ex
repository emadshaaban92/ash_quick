defmodule AshQuick.Scope do
  @moduledoc """
  The actor-provenance contract: who really did this, and where from.

  `Ash.Scope.ToOpts` answers *which actor* an action runs as. It has nothing to
  say about the human behind that actor when someone is impersonating, the IP
  the request arrived on, or the actor's own timezone and locale. AshQuick
  needs all four — audit records the first two on every row, and an
  impersonation banner and a localised UI need the rest — so it declares them
  itself, additively, and generates the wiring rather than documenting a
  convention and hoping.

      defmodule MyApp.Scope do
        use AshQuick.Scope,
          actor: :current_user,
          tenant: :current_tenant,
          real_actor: :real_user,
          ip: :ip

        defstruct [:current_user, :current_tenant, :real_user, :ip, :theme]
      end

  That generates the `Ash.Scope.ToOpts` implementation *and*
  `AshQuick.Scope.ToProvenance`, and it fails the compile if any name given
  above is not a field of the struct below. The struct itself stays the host's:
  AshQuick names a floor of fields it can read, and `:theme` above is none of
  its business.

  ## Options

  Each option names a **struct field**, not a value.

    * `:actor` — required. The actor `Ash.Scope.ToOpts.get_actor/1` returns.
    * `:tenant` — the tenant. Omit it in a single-tenant application.
    * `:real_actor` — the human behind the actor. **Defaults to the actor
      field.** A host with no impersonation is not a special case: the two are
      simply always equal, and the audit column is ready for the day they are
      not.
    * `:impersonating?` — a boolean field saying an impersonation is in
      progress. Omitted, it is derived by comparing the actor with the real
      actor.
    * `:ip` — the address the request came from. Omitted, provenance carries
      `nil` — correct for a scope built off a request, which has no IP.
    * `:timezone` / `:locale` — the actor's own, read through `timezone/1` and
      `locale/1`. Omitted, `AshQuick.Config.timezone/0` and
      `AshQuick.Config.locale/0` apply. Note that the formatters in
      `AshQuick.Config` render off those application-wide values, not off the
      scope.

  ## Why a macro over a protocol

  A behaviour would need configuration naming the one module to call, which
  breaks the moment a host has more than one scope shape (web, job, API), and
  it would sit crosswise to `Ash.Scope.ToOpts`, which is already a protocol. A
  bare protocol dispatches correctly but enforces nothing: a missing `defimpl`
  first shows up as a `Protocol.UndefinedError` inside audit, in production.

  So the protocol is the dispatch and the macro is the enforcement — the same
  split `use Ash.Resource` already is. `contract_violations/1` describes a
  scope that satisfies neither, for a host that wants to assert the contract
  over its own scope modules in a test.

  ## The context is the larger half

  Exposing the real actor on the scope alone solves nothing, because the code
  that needs it holds a changeset, not a scope. The generated `get_context/1`
  therefore puts an `AshQuick.Scope.Provenance` struct into the action's
  **shared** context under a library-owned key, and Ash carries shared context
  down through nested and related actions. `provenance/1` reads it back off a
  changeset, a query, or a hook's context — so the whole path, scope to context
  to changeset to audit row, belongs to the library instead of being
  reproduced from memory in each project.

  The generated `get_context/1` owns `shared.#{inspect(:ash_quick)}` and
  nothing else, so a per-call `context: %{shared: %{...}}` deep-merges
  alongside it as usual.
  """

  alias AshQuick.Scope.Provenance
  alias AshQuick.Scope.ToProvenance

  @context_key Provenance.context_key()

  @required_options [:actor]
  @optional_options [:tenant, :real_actor, :impersonating?, :ip, :timezone, :locale]
  @options @required_options ++ @optional_options

  defmacro __using__(opts) do
    fields = __validate_options__(opts, __CALLER__.module)

    quote do
      @ash_quick_scope_fields unquote(Macro.escape(fields))
      @before_compile AshQuick.Scope
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    fields = Module.get_attribute(env.module, :ash_quick_scope_fields)
    __validate_fields__(env, fields)

    quote do
      defimpl Ash.Scope.ToOpts, for: unquote(env.module) do
        unquote(getter(:get_actor, fields[:actor]))
        unquote(getter(:get_tenant, fields[:tenant]))

        def get_context(scope) do
          {:ok, %{shared: %{unquote(@context_key) => AshQuick.Scope.provenance(scope)}}}
        end

        # Tracers are configured in config files, and a scope that could turn
        # authorization off is a hole nobody asked for.
        def get_tracer(_scope), do: :error
        def get_authorize?(_scope), do: :error
      end

      defimpl AshQuick.Scope.ToProvenance, for: unquote(env.module) do
        unquote(getter(:get_real_actor, fields[:real_actor]))
        unquote(getter(:get_impersonating?, fields[:impersonating?]))
        unquote(getter(:get_ip, fields[:ip]))
        unquote(getter(:get_timezone, fields[:timezone]))
        unquote(getter(:get_locale, fields[:locale]))
      end
    end
  end

  defp getter(name, nil) do
    quote do
      def unquote(name)(_scope), do: :error
    end
  end

  defp getter(name, field) do
    quote do
      def unquote(name)(%{unquote(field) => value}), do: {:ok, value}
    end
  end

  @doc false
  def __validate_options__(opts, module) when is_list(opts) do
    Enum.each(opts, fn
      {key, field} when key in @options and is_atom(field) and not is_nil(field) ->
        :ok

      {key, _field} when key in @options ->
        raise ArgumentError,
              "#{inspect(module)}: `use AshQuick.Scope` expects #{inspect(key)} to name a " <>
                "struct field as an atom"

      {key, _field} ->
        raise ArgumentError,
              "#{inspect(module)}: unknown `use AshQuick.Scope` option #{inspect(key)}. " <>
                "Known options: #{inspect(@options)}"

      other ->
        raise ArgumentError,
              "#{inspect(module)}: `use AshQuick.Scope` expects a keyword list, got " <>
                inspect(other)
    end)

    Enum.each(@required_options, fn key ->
      Keyword.has_key?(opts, key) ||
        raise ArgumentError,
              "#{inspect(module)}: `use AshQuick.Scope` requires #{inspect(key)}, naming the " <>
                "struct field that holds it"
    end)

    Keyword.put_new(opts, :real_actor, opts[:actor])
  end

  def __validate_options__(_opts, module) do
    raise ArgumentError,
          "#{inspect(module)}: `use AshQuick.Scope` expects a literal keyword list of options"
  end

  @doc false
  def __validate_fields__(env, fields) do
    declared = struct_fields!(env)

    for {option, field} <- fields, field not in declared do
      raise ArgumentError,
            "#{inspect(env.module)}: `use AshQuick.Scope` names #{inspect(field)} as its " <>
              "#{inspect(option)}, but the struct has no such field. Struct fields: " <>
              "#{inspect(declared)}"
    end

    :ok
  end

  defp struct_fields!(env) do
    Enum.map(Macro.struct_info!(env.module, env), & &1.field)
  rescue
    _ ->
      reraise ArgumentError,
              [
                message:
                  "#{inspect(env.module)}: `use AshQuick.Scope` requires the module to define " <>
                    "a struct, so that the fields it names can be read off one"
              ],
              __STACKTRACE__
  end

  @doc """
  The `AshQuick.Scope.Provenance` for a scope, a changeset, a query, an action
  input, or a hook's context.

  Given a scope, it is read through `AshQuick.Scope.ToProvenance`. Given
  anything carrying an action's context, it is read back out of the shared
  context the generated `get_context/1` put it in.

  Never returns `nil`, and never raises on a subject that knows nothing about
  the contract: a scope implementing only `Ash.Scope.ToOpts` yields its actor
  as its own real actor, which is what a host without impersonation means
  anyway. That is a documented default rather than a silent one — the columns
  fill in correctly, and `contract_violations/1` is what reports the gap.
  """
  def provenance(subject) do
    case ToProvenance.impl_for(subject) do
      nil -> %Provenance{real_actor: actor(subject)}
      _impl -> build(subject)
    end
  end

  defp build(subject) do
    actor = actor(subject)
    real_actor = get(ToProvenance.get_real_actor(subject), actor)

    %Provenance{
      real_actor: real_actor,
      impersonating?:
        get(ToProvenance.get_impersonating?(subject), impersonating?(actor, real_actor)),
      ip: get(ToProvenance.get_ip(subject), nil),
      timezone: get(ToProvenance.get_timezone(subject), nil),
      locale: get(ToProvenance.get_locale(subject), nil)
    }
  end

  defp get({:ok, value}, _default), do: value
  defp get(:error, default), do: default

  # By id rather than by value, since two loads of the same user differ on
  # whichever calculations each happened to carry.
  defp impersonating?(actor, real_actor), do: identity(real_actor) != identity(actor)

  defp identity(%{id: id}), do: id
  defp identity(other), do: other

  @doc """
  The actor of a scope, a changeset, a query, an action input, or a hook's
  context — `nil` when there is none.
  """
  # Ash implements `ToOpts` for scopes and for hook contexts, but not for the
  # three subjects themselves, so those are read off the struct.
  def actor(%Ash.Changeset{context: context}), do: get_in(context, [:private, :actor])
  def actor(%Ash.Query{context: context}), do: get_in(context, [:private, :actor])
  def actor(%Ash.ActionInput{context: context}), do: get_in(context, [:private, :actor])

  def actor(subject) do
    case Ash.Scope.ToOpts.impl_for(subject) do
      nil -> nil
      _impl -> get(Ash.Scope.ToOpts.get_actor(subject), nil)
    end
  end

  @doc """
  The tenant of a scope, a changeset, a query, an action input, or a hook's
  context — `nil` when there is none.
  """
  def tenant(%Ash.Changeset{tenant: tenant}), do: tenant
  def tenant(%Ash.Query{tenant: tenant}), do: tenant
  def tenant(%Ash.ActionInput{tenant: tenant}), do: tenant

  def tenant(subject) do
    case Ash.Scope.ToOpts.impl_for(subject) do
      nil -> nil
      _impl -> get(Ash.Scope.ToOpts.get_tenant(subject), nil)
    end
  end

  @doc """
  The human behind the actor. Equal to the actor unless an impersonation is in
  progress.
  """
  def real_actor(subject), do: provenance(subject).real_actor

  @doc """
  Whether the actor and the real actor differ.
  """
  def impersonating?(subject), do: provenance(subject).impersonating?

  @doc """
  The IP the request came from, or `nil` off a request.
  """
  def ip(subject), do: provenance(subject).ip

  @doc """
  The actor's timezone, falling back to `AshQuick.Config.timezone/0`.
  """
  def timezone(subject), do: provenance(subject).timezone || AshQuick.Config.timezone()

  @doc """
  The actor's locale, falling back to `AshQuick.Config.locale/0`.
  """
  def locale(subject), do: provenance(subject).locale || AshQuick.Config.locale()

  @doc """
  The ways `module` falls short of the provenance contract, as a list of
  sentences — empty when it satisfies it.

  A scope that implements only `Ash.Scope.ToOpts` still *works* (see
  `provenance/1`), so this is the thing that says the real actor and IP columns
  are going to be the actor and `nil` forever rather than leaving that to be
  discovered from the data. Nothing calls it on a host's behalf: assert it is
  empty over each scope module in a test.
  """
  def contract_violations(module) when is_atom(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        ["#{inspect(module)} is not a loadable module."]

      not function_exported?(module, :__struct__, 0) ->
        ["#{inspect(module)} defines no struct, so no scope can be built from it."]

      true ->
        violations(struct(module))
    end
  end

  defp violations(scope) do
    Enum.reject(
      [
        unless(Ash.Scope.ToOpts.impl_for(scope),
          do: "#{name(scope)} does not implement Ash.Scope.ToOpts, so no action can run under it."
        ),
        unless(ToProvenance.impl_for(scope),
          do:
            "#{name(scope)} does not implement AshQuick.Scope.ToProvenance, so its real actor " <>
              "and IP are unknown. Add `use AshQuick.Scope` to it."
        ),
        unless(provenance_in_context?(scope),
          do:
            "#{name(scope)} does not carry its provenance into action context under " <>
              "#{inspect(@context_key)}, so audit cannot record who really acted. Let " <>
              "`use AshQuick.Scope` generate `get_context/1`."
        )
      ],
      &is_nil/1
    )
  end

  defp provenance_in_context?(scope) do
    match?(
      {:ok, %{shared: %{@context_key => %Provenance{}}}},
      Ash.Scope.ToOpts.get_context(scope)
    )
  rescue
    _ -> false
  end

  defp name(scope), do: inspect(scope.__struct__)
end
