defmodule AshQuick.AshTypes.Attachment.Value do
  @moduledoc """
  Runtime value carried by `AshQuick.AshTypes.Attachment` fields.

  Stores only the storage-relevant fields — display metadata such as alt
  text or featured flags lives on a wrapping embed, not here.

  `original_filename` and `byte_size` are best-effort: present when the
  upload pipeline supplies them (client-reported), `nil` for seeded
  fixtures or callers that don't bother. Server-side verification of
  `byte_size` is future hardening.
  """

  @derive Jason.Encoder
  defstruct [:key, :file_type, :original_filename, :byte_size]

  @type file_type :: :image | :video | :document

  @type t :: %__MODULE__{
          key: String.t(),
          file_type: file_type() | nil,
          original_filename: String.t() | nil,
          byte_size: non_neg_integer() | nil
        }

  @doc "What the attachment is called on a page: the name it was uploaded with, or its key's."
  def display_name(%__MODULE__{original_filename: name}) when is_binary(name) and name != "",
    do: name

  def display_name(%__MODULE__{key: key}), do: Path.basename(key)
end
