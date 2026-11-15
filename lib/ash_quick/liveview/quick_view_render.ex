defmodule AshQuick.LiveView.QuickView.Render do
  @moduledoc false
  # What the generated `render/1` draws: the not-found page, the generic
  # list, details and form views, and whether a custom form template is
  # skipped for the generic one.
  import Phoenix.Component, only: [assign: 3]
  alias Ash.Resource.Actions

  def render_unknown_action(assigns) do
    assigns
    |> assign(:record, nil)
    |> AshQuick.LiveView.Components.DetailsView.details_view()
  end

  def forbidden_form?(%{ash_action: %action_type{}} = assigns)
      when action_type in [Actions.Create, Actions.Update, Actions.Destroy] do
    AshQuick.LiveView.Components.FormView.forbidden?(assigns)
  end

  def forbidden_form?(_assigns), do: false

  def do_render(assigns, %{id: nil}, %Actions.Read{get?: false}) do
    assigns
    |> AshQuick.LiveView.Components.ListView.list_view()
  end

  def do_render(assigns, %{id: id}, %Actions.Read{}) when not is_nil(id) do
    assigns
    |> AshQuick.LiveView.Components.DetailsView.details_view()
  end

  def do_render(assigns, _, _) do
    assigns
    |> AshQuick.LiveView.Components.FormView.form_view()
  end
end
