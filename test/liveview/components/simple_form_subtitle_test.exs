defmodule AshQuick.Components.SimpleFormSubtitleTest do
  @moduledoc """
  The record a form edits, named under its title, reads in its own direction:
  a phone number left to right on an Arabic page too.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  for {label, subtitle, dir} <- [
        {"a phone number", "+20 100 123 4567", "ltr"},
        {"a name", "Acme Inc.", "auto"}
      ] do
    test "names #{label} with dir=#{dir}" do
      assigns = %{subtitle: unquote(subtitle)}

      html =
        rendered_to_string(~H"""
        <AshQuick.Components.simple_form
          for={to_form(%{})}
          id="f"
          form_title="Edit"
          form_subtitle={@subtitle}
        >
          <p>fields</p>
        </AshQuick.Components.simple_form>
        """)

      assert html =~ ~s(<span dir="#{unquote(dir)}">#{unquote(subtitle)}</span>)
    end
  end
end
