defmodule AshQuick.AshTypes.Text do
  @moduledoc """
  An Ash type for long-form text content.

  A subtype of `:string` with no additional constraints. The type distinction
  is used by AshQuick views to render appropriate UI:

  ## Behavior in AshQuick views

    * **Forms:** Renders a `<textarea>` spanning the full form width,
      instead of a single-line text input.
    * **List/Details views:** Renders with `text-wrap` and `overflow-x-auto`
      styles for readable display of long content.

  ## Usage

      attribute :description, AshQuick.AshTypes.Text, public?: true
  """
  use Ash.Type.NewType, subtype_of: :string
end
