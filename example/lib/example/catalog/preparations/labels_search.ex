defmodule Example.Catalog.Preparations.LabelsSearch do
  @moduledoc "The `:search` argument of `Example.Catalog.Label`'s lookup action."
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    case Ash.Query.get_argument(query, :search) do
      nil ->
        query

      search ->
        Ash.Query.filter(query, ilike(name, ^"%#{search}%"))
    end
  end
end
