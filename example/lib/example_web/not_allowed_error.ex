defmodule ExampleWeb.NotAllowedError do
  @moduledoc """
  Raised when a signed-in user navigates to a route their role does not hold.

  `Plug.Exception` maps it to a 403, so reaching past a missing sidebar link by
  typing the URL is a visible refusal rather than an empty page.
  """
  defexception [:path, :user, plug_status: 403]

  @impl true
  def message(%{path: path}), do: "not allowed to access #{path}"
end
