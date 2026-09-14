defmodule Example.Catalog.Preparations.CategoriesSearch do
  @moduledoc "The `:search` argument of `Example.Catalog.Category`'s lookup action."
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    case Ash.Query.get_argument(query, :search) do
      nil ->
        query

      search ->
        Ash.Query.filter(query, ilike(name, ^"%#{search}%") or ilike(code, ^"%#{search}%"))
    end
  end
end
