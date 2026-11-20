defmodule AshQuick.LiveView.UtilsTest do
  @moduledoc """
  `Utils.label_fields/2` is what every display-label load asks, including the
  details header's writers. An application configures exactly one actor
  resource, so no page can open against an actor labelled by an aggregate; the
  rule that load follows is pinned here instead, and the pages it shares with
  in `ExampleWeb.TenantLabelsScenarioTest`.
  """
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.Utils
  alias Example.Test.CountedLabels.{Bin, Box}

  test "a label counting records held per tenant is loaded only with a tenant" do
    assert Utils.label_fields(Bin, nil) == []
    assert Utils.label_fields(Bin, Ash.UUID.generate()) == [:item_count]
  end

  test "an attribute label is loaded with or without a tenant" do
    assert Utils.label_fields(Box, nil) == [:code]
    assert Utils.label_fields(Box, Ash.UUID.generate()) == [:code]
  end
end
