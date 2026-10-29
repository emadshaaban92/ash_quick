defmodule AshQuick.Nav.Labels do
  @moduledoc false
  # Gives the nav the `gettext` calls for the labels it draws: an entry's
  # `label:`, the one an entry without one takes from its path, and every
  # group's. A label derived from a QuickView's resource is extracted from
  # that QuickView, and the path of one the nav only discovers from the
  # router's `quick_view/3` route.
  use Spark.Dsl.Transformer

  alias AshQuick.Nav.Entry
  alias AshQuick.Nav.Info
  alias Spark.Dsl.Transformer

  @impl true
  def transform(dsl_state) do
    labels =
      dsl_state
      |> Transformer.get_entities([:nav])
      |> Enum.map(&label/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    case AshQuick.Labels.Gettext.calls(labels) do
      nil -> {:ok, dsl_state}
      calls -> {:ok, Transformer.eval(dsl_state, [], calls)}
    end
  end

  defp label(%Entry{label: nil, path: path}), do: Info.path_label(path)
  defp label(entity), do: entity.label
end
