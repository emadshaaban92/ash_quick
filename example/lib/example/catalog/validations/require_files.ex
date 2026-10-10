defmodule Example.Catalog.Validations.RequireFiles do
  @moduledoc """
  Refuses a change that leaves an array of attachments empty.

  `present/1` asks only whether a value is `nil`, and an array attribute that
  holds no files is `[]`.
  """
  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, opts, _context) do
    field = Keyword.fetch!(opts, :field)

    case Ash.Changeset.get_attribute(changeset, field) do
      empty when empty in [nil, []] -> {:error, field: field, message: "must be present"}
      _files -> :ok
    end
  end
end
