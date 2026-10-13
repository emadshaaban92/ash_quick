defmodule Example.Test.HostNamedHelpersLive.Quick do
  @moduledoc """
  A QuickView that defines helpers of its own under names a host is likely to
  pick, and must still compile.

  `use AshQuick.LiveView.QuickView` imports every public function of
  `AshQuick.Components` into the module. A local function with the same name
  and arity as one of them is a compile error ("imported ... conflicts with
  local function"), so a new public function there breaks any host that
  already had one by that name. Compiling this module is the test: the
  example suite fails to build when the import surface grows a name below.
  """
  use AshQuick.LiveView.QuickView,
    resource: Example.Test.DigitsOnly,
    list: [fields: [:code, :name]],
    details: [fields: [:code, :name]]

  # A template helper by the name `AshQuick.LiveView.FieldErrors.for_field/1`
  # had before it moved out of `AshQuick.Components`.
  def field_errors(%Phoenix.HTML.FormField{errors: errors}), do: errors

  # Called unqualified, as from a template: this call is what an import of the
  # same name makes ambiguous.
  def own_errors(field), do: field_errors(field)
end
