defmodule AshQuick.Components.InputTest do
  @moduledoc """
  A `class` handed to `AshQuick.Components.input/1` is added to the input's
  own classes, on every type it draws, and never to the wrapper, which takes
  half a form grid's row on every type.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  for {type, own} <- [
        {"text", "input"},
        {"select", "select"},
        {"textarea", "textarea"},
        {"checkbox", "checkbox"}
      ] do
    test "adds a class to a #{type} input's own" do
      html =
        render_component(&AshQuick.Components.input/1,
          type: unquote(type),
          name: "x",
          value: "1",
          options: [],
          class: "host-class"
        )

      [class] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[name='x']:not([type='hidden'])")
        |> LazyHTML.attribute("class")

      classes = String.split(class)
      assert unquote(own) in classes
      assert "host-class" in classes

      [wrapper] =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.filter("div")
        |> LazyHTML.attribute("class")

      assert String.split(wrapper) == ["sm:col-span-2"]
    end
  end
end
