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

  @type file_type :: :image | :video

  @type t :: %__MODULE__{
          key: String.t(),
          file_type: file_type() | nil,
          original_filename: String.t() | nil,
          byte_size: non_neg_integer() | nil
        }
end
