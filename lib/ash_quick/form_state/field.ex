defmodule AshQuick.FormState.Field do
  @moduledoc """
  One field of an `AshQuick.FormState`.

    * `:name` — the field as the QuickView names it: `:brand`, not `:brand_id`.
    * `:inputs` — the params it posts: `[:brand_id]`.
    * `:kind` — the kind of input its type takes: `:text`, `:number`,
      `:date`, `:time`, `:naive_datetime`, `:datetime`, `:long_text`,
      `:boolean`, `:password`, `:choice`, `:belongs_to`, `:many_to_many`,
      `:attachment`, `:attachments`, `:nested` or `:widget`. A type drawn by
      its own input (`config :ash_quick, form_inputs:`, see
      `AshQuick.FormInput`) keeps the kind of its storage: a money field is
      `:text` or `:number`.
    * `:label` and `:help` — what it is drawn with.
    * `:required?` — starts as Ash's answer (`allow_nil? false`).
    * `:hidden?` and `:disabled?` — see `AshQuick.FormState.hide/3` and
      `AshQuick.FormState.disable/3`.
    * `:attrs` — extra HTML attributes for its input (see `AshQuick.FormState.put_attrs/3`).
    * `:source` — the Ash attribute, argument or relationship it is.

  Change it through the functions in `AshQuick.FormState`.
  """

  @type t :: %__MODULE__{
          name: atom(),
          inputs: [atom()],
          kind: atom(),
          label: String.t(),
          help: String.t() | nil,
          required?: boolean(),
          hidden?: boolean(),
          disabled?: boolean(),
          attrs: keyword(),
          source: struct()
        }

  @enforce_keys [:name, :inputs, :kind, :label, :source]
  defstruct [
    :name,
    :inputs,
    :kind,
    :label,
    :help,
    :source,
    required?: false,
    hidden?: false,
    disabled?: false,
    attrs: []
  ]
end
