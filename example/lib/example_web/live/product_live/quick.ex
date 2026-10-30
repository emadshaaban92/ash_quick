defmodule ExampleWeb.ProductLive.Quick do
  @moduledoc """
  The page worth opening first.

  It shows most of what a QuickView does without being told: two relationship
  dropdowns on the form, a `Money` column, a textarea for `:text`, an array of
  atoms as a multi-select, an array of embedded attachments with an upload
  behind each, a saved filter, and `:reprice` offered as a row action because
  the resource defines it and the actor's policy allows it.

  `:bulk_actions` is the one thing here that *is* told, and it is worth reading
  for why. Left out, the menu over a selection would be derived: every public
  update and destroy that takes no input — `Activate`, `Deactivate` and
  `Delete` here. An action that takes input is never derived, because only the
  page knows whether one value makes sense for every selected row. One price
  for a whole range does, so this page names `:reprice`, which opens its form
  in the modal and applies the price to every selected row. Naming anything
  means naming everything, so the three defaults are named too, in the order
  the menu shows them. "Discount 10%" is the other kind of entry: a custom item
  whose event this module handles itself.
  """
  use Gettext, backend: ExampleWeb.Gettext

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
        :inserted_at,
        :updated_at
      ]
    ]

  @discount Decimal.new("0.9")

  @doc """
  This page's bulk menu, in order.

  Action names need no guard: each is offered only to an actor whose policy
  allows it, so an editor's menu has no `Reprice`. A custom item is the host's
  to guard, which is why this is a function of the socket rather than a list.

  "Discount 10%" stays beside `Reprice` because it does what one set of inputs
  cannot: each row's new price comes from its own old one. `Reprice` sets the
  same price on every row.

  AshQuick translates the title as it draws it, as it does every label. A
  function is something `mix ash_quick.gen.gettext` cannot read, so the title is
  marked for `mix gettext.extract` instead, in the `ash_quick` domain.
  """
  def bulk_actions(socket) do
    discount =
      if Ash.can?({Product, :reprice}, socket.assigns.scope, log_policy_breakdown?: false),
        do: %{title: dgettext_noop("ash_quick", "Discount 10%"), func: JS.push("discount")}

    [:reprice, discount, :activate, :deactivate, :destroy]
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
