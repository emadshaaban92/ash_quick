if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshQuick.Gen.Resource do
    @example "mix ash_quick.gen.resource MyApp.Catalog.Product"

    @shortdoc "Adds the AshQuick extension to an existing resource, and reports the columns it adds"

    @moduledoc """
    Adds the AshQuick extension to a resource that already exists, and says what
    that costs.

    ```bash
    #{@example}
    ```

    `extensions: [AshQuick]` is the whole opt-in, and it **adds columns** — so it
    means a migration. This task names them before you run one, reads them off
    the resource as it stands so add-if-absent is accounted for, and queues
    `mix ash.codegen`.

    It also says what the resource still owes AshQuick: a display label, which
    it refuses to compile without, since a uuid would only look like an answer.

    The extension is added by `mix ash.extend`, which this task composes.
    """

    use Igniter.Mix.Task

    @impl Igniter.Mix.Task
    def info(_argv, _parent) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        example: @example,
        positional: [:resource],
        composes: ["ash.extend", "ash.codegen"]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      resource = Igniter.Project.Module.parse(igniter.args.positional.resource)

      cond do
        not match?({:module, _module}, Code.ensure_compiled(resource)) ->
          Igniter.add_issue(igniter, "#{inspect(resource)} does not exist.")

        not Ash.Resource.Info.resource?(resource) ->
          Igniter.add_issue(igniter, "#{inspect(resource)} is not an Ash resource.")

        AshQuick in Spark.extensions(resource) ->
          Igniter.add_notice(igniter, "#{inspect(resource)} already carries AshQuick.")

        true ->
          extend(igniter, resource)
      end
    end

    defp extend(igniter, resource) do
      igniter
      |> Igniter.compose_task("ash.extend", [inspect(resource), "AshQuick"])
      |> Ash.Igniter.codegen("ash_quick_#{short_name(resource)}")
      |> Igniter.add_notice(report(resource))
      |> maybe_warn_label(resource)
    end

    # Read off the resource as it stands, because every one of these is
    # add-if-absent: a resource that already defines the attribute keeps exactly
    # what it wrote, and reporting a column it already has would send someone
    # looking for a migration that is not there.
    defp report(resource) do
      case Enum.reject(columns(resource), &Ash.Resource.Info.attribute(resource, elem(&1, 0))) do
        [] ->
          """
          #{inspect(resource)} now carries AshQuick, and already has every \
          column the extension would have added. Run `mix ash.codegen` and read \
          the migration anyway.
          """

        columns ->
          """
          #{inspect(resource)} now carries AshQuick, which adds #{length(columns)} column(s):

          #{Enum.map_join(columns, "\n", fn {name, description} -> "  * `#{name}` — #{description}" end)}

          `mix ash.codegen` is queued. Read the migration before running it.

          Where one of these is not wanted, the `ash_quick` section is where it \
          is turned off — `versioning do enabled? false end` for a row only one \
          writer touches, `bookkeeping do created_by false end` for a resource \
          nobody creates. Turning one off after the migration means another \
          migration.
          """
      end
    end

    defp columns(resource) do
      [
        {:version, "integer, default 1 — the optimistic lock every update filters on"},
        {:created_at, "utc_datetime_usec, always selected"},
        {:updated_at, "utc_datetime_usec, always selected"}
      ] ++ actor_columns() ++ activation_column(resource)
    end

    # Only when the application named an actor resource: with none configured
    # there is nobody for the relationships to point at, and AshQuick generates
    # neither.
    defp actor_columns do
      case AshQuick.Config.actor_resource() do
        nil ->
          []

        actor ->
          [
            {:created_by_id, "a reference to #{inspect(actor)}"},
            {:updated_by_id, "a reference to #{inspect(actor)}"}
          ]
      end
    end

    # `active` follows the declaration rather than the extension, so it is only
    # listed for a resource that has already asked for it.
    defp activation_column(resource) do
      if AshQuick.Info.activation?(resource) do
        [{:active, "boolean, default true — from the declared `activation`"}]
      else
        []
      end
    end

    # The one thing the extension will refuse to compile without, and the error
    # arrives on the next `mix compile` rather than here — so it is said here.
    defp maybe_warn_label(igniter, resource) do
      if labelled?(resource) do
        igniter
      else
        Igniter.add_warning(igniter, """
        #{inspect(resource)} has neither a `:display_name` nor a `:name`, so \
        AshQuick has no field to name a record by — in a dropdown option, a \
        details header, a print filename — and will refuse to compile it. \
        Declare one:

            ash_quick do
              display do
                label :code
              end
            end

        `label` names an attribute, calculation or aggregate. A composed label \
        belongs in a calculation.
        """)
      end
    end

    defp labelled?(resource) do
      Enum.any?([:display_name, :name], &Ash.Resource.Info.field(resource, &1))
    end

    defp short_name(resource) do
      resource |> Module.split() |> List.last() |> Macro.underscore()
    end
  end
else
  defmodule Mix.Tasks.AshQuick.Gen.Resource do
    @shortdoc "Adds the AshQuick extension to an existing resource, and reports the columns it adds"

    @moduledoc @shortdoc

    use Mix.Task

    @impl Mix.Task
    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_quick.gen.resource' requires igniter to be run.

      Please install igniter and try again.

      For more information, see: https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
