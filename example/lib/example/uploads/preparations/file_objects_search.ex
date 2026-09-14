defmodule Example.Uploads.Preparations.FileObjectsSearch do
  @moduledoc "The `:search` argument of `Example.Uploads.FileObject`'s lookup action."
  use Ash.Resource.Preparation

  require Ash.Query

  @impl true
  def prepare(query, _opts, _context) do
    case Ash.Query.get_argument(query, :search) do
      nil -> query
      search -> Ash.Query.filter(query, ilike(key, ^"%#{search}%"))
    end
  end
end
