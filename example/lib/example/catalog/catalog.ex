defmodule Example.Catalog do
  @moduledoc """
  The resources the QuickViews are built over.

  Between them they cover the shapes a page has to render: a plain record
  (`Brand`), a self-referencing tree with an attachment (`Category`), a record
  with relationships, money, long text and an array of embedded attachments
  (`Product`), and an append-only log that carries only half the bookkeeping
  declaration (`PriceChange`).

  `Store` is the odd one: it is the tenant the rest are partitioned by rather
  than a shape to render. Only `Product` is actually scoped to it — enough to
  show the seam without making every page in the app read as a special case.
  """
  use Ash.Domain

  resources do
    resource Example.Catalog.Store
    resource Example.Catalog.Brand
    resource Example.Catalog.Category
    resource Example.Catalog.Product
    resource Example.Catalog.PriceChange
  end
end
