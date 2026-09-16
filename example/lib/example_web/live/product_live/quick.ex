defmodule ExampleWeb.ProductLive.Quick do
  @moduledoc """
  The page worth opening first.

  It shows most of what a QuickView does without being told: two relationship
  dropdowns on the form, a `Money` column, a textarea for `:text`, an array of
  atoms as a multi-select, an array of embedded attachments with an upload
  behind each, a saved filter, and `:reprice` offered as a row action because
  the resource defines it and the actor's policy allows it.

  `:bulk_actions` is the one thing here that *is* told, and it is worth reading
  for why. Every input-less update and every destroy the actor may run is
  already offered over a selection, derived from the resource — `Activate`,
  `Deactivate` and `Delete` appear on this page without being named. What
  cannot be derived is an operation needing a value nobody has been asked for.
  `:reprice` takes a price, so it is not in the automatic list; "Discount 10%"
  below supplies one and runs it over the selection.
  """
  require Ash.Expr

  alias AshQuick.LiveView.ActionErrors
  alias Example.Catalog.Product
  alias Phoenix.LiveView.JS

  use AshQuick.LiveView.QuickView,
    resource: Example.Catalog.Product,
    load: [brand: [:name], category: [:name], store: [:name]],
    filters: [
      %{
        "name" => "on_sale",
        "label" => "On sale",
        "expression" => Ash.Expr.expr(:sale in tags or :clearance in tags)
      }
    ],
    list: [
      bulk_actions: &__MODULE__.bulk_actions/1,
      fields: [
        :sku,
        :name,
        {[brand: :name], label: "Brand"},
        {[category: :name], label: "Category"},
        :price,
        :tags,
        {:images, widget: &ExampleWeb.ImageWidgets.image/1},
        :store,
        :active
      ],
      new_action_label: "Add Product"
    ],
    details: [
      fields: [
        :sku,
        :name,
        :description,
        {[brand: :name], label: "Brand"},
        {[category: :name], label: "Category"},
        :price,
        :tags,
        {:images, widget: &ExampleWeb.ImageWidgets.image/1},
        :store,
        :active,
        :created_at,
        :updated_at
      ]
    ]

  @discount Decimal.new("0.9")

  @doc """
  The bulk actions this page adds to the ones derived from the resource.

  Taken as a function of the socket rather than as a list, so the offer can
  depend on who is reading: `:reprice` is an admin's, and an editor is shown
  nothing they would only be refused. The record-less `Ash.can?/3` here is the
  same question the derived actions are filtered by.
  """
  def bulk_actions(socket) do
    if Ash.can?({Product, :reprice}, socket.assigns.scope, log_policy_breakdown?: false) do
      [%{title: "Discount 10%", func: JS.push("discount")}]
    else
      []
    end
  end

  @doc """
  Reprices every selected product.

  `"discount"` is not a name QuickView handles, so the list's event hook passes
  it through to here — which is the whole contract a custom bulk action relies
  on. The selection is read back off the socket the same way the built-in
  handler reads it.

  Every selected row is attempted rather than stopping at the first refusal. A
  discount is one write per row and the writes are not in a transaction
  together, so stopping early does not undo the rows already repriced — it only
  loses the fact that they were. What the operator needs to know after a partial
  run is how far it got, and which rows are still waiting.

  Matched on the assigns a list carries rather than on the name alone. One
  module serves both routes, and the details hook passes an unhandled name
  through the same way the list's does — so `"discount"` pushed at
  `/products/:id` reaches here too, where there is no `:selected_rows` and no
  `:data` to read. That is a forged event, and the clause below answers it the
  way the reduce already answers a forged one: by declining, not by raising.
  """
  @impl true
  def handle_event("discount", _params, %{assigns: %{data: _, selected_rows: _}} = socket) do
    selected = Map.keys(socket.assigns.selected_rows)
    products = Enum.filter(socket.assigns.data.results, &(&1.id in selected))

    {repriced, errors} =
      Enum.reduce(products, {[], []}, fn product, {repriced, errors} ->
        product
        |> Product.reprice(Money.mult!(product.price, @discount), scope: socket.assigns.scope)
        |> case do
          {:ok, _repriced} -> {[product.id | repriced], errors}
          # Not a bang call. The link is rendered only for an actor who may run
          # the action, so an event arriving without it was forged — and a forged
          # event is a refusal to show rather than a page to crash.
          {:error, error} -> {repriced, [error | errors]}
        end
      end)

    case Enum.reverse(errors) do
      [] ->
        {:noreply,
         socket
         |> assign(selected_rows: %{})
         |> put_flash(:info, "Repriced #{length(repriced)} products.")}

      # The selection keeps exactly the rows that were not repriced, so running
      # it again discounts each row once instead of compounding the discount on
      # the rows that already took it. `ActionErrors` is what turns the error
      # into a sentence.
      [error | _] ->
        {:noreply,
         socket
         |> assign(selected_rows: Map.drop(socket.assigns.selected_rows, repriced))
         |> put_flash(:error, discount_error(repriced, products, error))}
    end
  end

  # A page with no selection to reprice — the details view. Nothing drew the
  # control there, so there is nothing to tell the reader about it either.
  def handle_event("discount", _params, socket), do: {:noreply, socket}

  defp discount_error([], _products, error), do: ActionErrors.user_facing_message(error)

  defp discount_error(repriced, products, error) do
    "Repriced #{length(repriced)} of #{length(products)} products. " <>
      ActionErrors.user_facing_message(error)
  end
end
