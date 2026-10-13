defmodule ExampleWeb.HostNamedHelpersTest do
  @moduledoc """
  A QuickView's own helpers keep their names. See
  `Example.Test.HostNamedHelpersLive.Quick`: this file only checks that the
  module built and that the name resolves to the host's function.
  """
  use ExUnit.Case, async: true

  alias Example.Test.HostNamedHelpersLive.Quick

  test "a QuickView can define its own field_errors/1" do
    field = %Phoenix.HTML.FormField{
      id: "form_code",
      name: "form[code]",
      errors: [{"mine", []}],
      field: :code,
      form: %Phoenix.HTML.Form{},
      value: nil
    }

    assert Code.ensure_loaded?(Quick)
    assert Quick.own_errors(field) == [{"mine", []}]
  end
end
