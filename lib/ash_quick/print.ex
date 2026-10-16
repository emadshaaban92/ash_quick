defmodule AshQuick.Print do
  @moduledoc """
  Makes an action print: run from a QuickView — a row or bulk action, the
  details page, or an action form — what it wrote is rendered through a print
  template and sent to the browser.

      update :print do
        change {AshQuick.Print, template: MyApp.LetterTemplate, delivery: :print}
      end

  The render happens after the action has committed, so the action's
  transaction holds its locks only for its own writes. A render that fails
  leaves what the action recorded in place and says so; printing it again is
  the action's to offer. A bulk run renders the records it marked in one call
  to the template, in the order they were selected; behind a `where:`, the
  change marks only the records that pass it, and only those print.

  The change marks the records the action returns (`:ash_quick_print` in their
  metadata); only a QuickView reads the mark, so an action called from
  anywhere else (a seed, another action) simply runs.

  It goes on a create or an update action: those return the record to print.
  On a resource carrying the `AshQuick` extension, a print that could not work
  does not compile: one on a destroy action, one with options it refuses, or
  one in an application with neither ChromicPDF nor a `:pdf_renderer` of its
  own (see `AshQuick.PdfRenderer`).

  Options:

    * `:template` — a module implementing `AshQuick.PrintTemplate`.
    * `:delivery` — `:download` (the default) saves the PDF; `:print` opens the
      browser's print dialog on it, with no file to keep.
  """
  use Ash.Resource.Change

  @deliveries [:download, :print]

  @impl true
  def init(opts) do
    case {Keyword.get(opts, :template), Keyword.get(opts, :delivery, :download)} do
      {template, delivery}
      when is_atom(template) and not is_nil(template) and delivery in @deliveries ->
        {:ok, [template: template, delivery: delivery]}

      _ ->
        {:error, "expected `template:` a module and `delivery:` one of #{inspect(@deliveries)}"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      {:ok, Ash.Resource.put_metadata(record, :ash_quick_print, Map.new(opts))}
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
