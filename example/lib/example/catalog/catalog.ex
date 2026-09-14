defmodule Example.Catalog do
  @moduledoc """
  The resources the QuickViews are built over.

  Between them they cover the shapes a page has to render: a plain record
  (`Brand`), a self-referencing tree with an attachment (`Category`), a record
  with relationships, money, long text and an array of embedded attachments
  (`Product`), and an append-only log that carries only half the bookkeeping
  declaration (`PriceChange`).
  """
  use Ash.Domain

  resources do
    resource Example.Catalog.Brand
    resource Example.Catalog.Category
    resource Example.Catalog.Product
    resource Example.Catalog.PriceChange
  end
end
