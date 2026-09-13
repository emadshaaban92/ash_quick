defmodule AshQuick.Display.Transformer do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Spark.Dsl.Transformer

  @inferred_labels [:display_name, :name]
  @labelable_fields [Ash.Resource.Attribute, Ash.Resource.Calculation, Ash.Resource.Aggregate]

  # Every field the resource offers has to be in the DSL state before its label
  # can be resolved against them, and a calculation added by another extension's
  # transformer is a legitimate label.
  @impl true
  def after?(_), do: true

  # Resolves `label` while the resource compiles, so that reading it back is the
  # whole of answering "what is this record called?". The conventions are matched
  # here, once, and nowhere else — `AshQuick.Info` only reads what this wrote.
  @impl true
  def transform(dsl_state) do
    with {:ok, label} <- label(dsl_state) do
      {:ok, Transformer.set_option(dsl_state, [:ash_quick, :display], :label, label)}
    end
  end

  defp label(dsl_state) do
    case Transformer.get_option(dsl_state, [:ash_quick, :display], :label) do
      nil -> infer_label(dsl_state)
      declared -> validate(dsl_state, declared)
    end
  end

  # Both conventions are names a human recognises, and between them they cover
  # nearly every resource, so the common case stays zero-config. What is
  # deliberately not here is an `:id` rung: a uuid is the never-crash answer
  # rather than a label, and falling back to it turns "nobody has said what this
  # is called" into something that looks like an answer. Refusing instead puts
  # the question in front of whoever is adding the extension, with the resource
  # open.
  defp infer_label(dsl_state) do
    case Enum.find(@inferred_labels, &labelable_field?(dsl_state, &1)) do
      nil -> {:error, no_label_error(dsl_state)}
      label -> {:ok, label}
    end
  end

  defp no_label_error(dsl_state) do
    Spark.Error.DslError.exception(
      module: Transformer.get_persisted(dsl_state, :module),
      path: [:ash_quick, :display, :label],
      message: """
      This resource defines neither #{Enum.map_join(@inferred_labels, " nor ", &inspect/1)}, \
      so nothing has resolved what one of its records is called. A label is what \
      a relationship dropdown, a details header and a print filename show.

      Name the field it should be called by:

          ash_quick do
            display do
              label :some_field
            end
          end

      A resource with no single naming field composes one — `label` takes a \
      calculation or an aggregate as readily as an attribute:

          calculations do
            calculate :display_name, :string, expr(string_join([a.name, b.name], " — "))
          end

      A calculation named :display_name is picked up with no `display` block \
      at all.
      """
    )
  end

  defp validate(dsl_state, label) do
    if labelable_field?(dsl_state, label) do
      {:ok, label}
    else
      {:error,
       Spark.Error.DslError.exception(
         module: Transformer.get_persisted(dsl_state, :module),
         path: [:ash_quick, :display, :label],
         message:
           "`label #{inspect(label)}` names no attribute, calculation or aggregate on this resource."
       )}
    end
  end

  # A relationship is a field too, and naming one holds a struct rather than
  # something renderable, so it is not a label.
  defp labelable_field?(dsl_state, field) do
    case Ash.Resource.Info.field(dsl_state, field) do
      %struct{} -> struct in @labelable_fields
      _ -> false
    end
  end
end
