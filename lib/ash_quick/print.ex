defmodule AshQuick.Print do
  @moduledoc """
  Makes an update action print: run from a QuickView — a row or bulk action,
  the details page, or an action form — what it wrote is rendered through a
  print template and sent to the browser.

      update :print do
        change {AshQuick.Print, template: MyApp.LetterTemplate, delivery: :print}
      end

  The action, the render and the PDF are one transaction: a render that fails
  rolls the action back, so nothing is recorded without its print. A bulk run
  renders every record it wrote in one call to the template, in the order the
  records were selected.

  The change itself does nothing to the changeset: AshQuick reads it off the
  action, so an action called from anywhere else (a seed, another action)
  simply runs.

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
  def change(changeset, _opts, _context), do: changeset

  @impl true
  def atomic(changeset, _opts, _context), do: {:ok, changeset}

  @doc """
  The template and delivery `resource`'s `action_name` prints with, or `nil`
  when it does not print.
  """
  def of(resource, action_name) do
    case Ash.Resource.Info.action(resource, action_name) do
      %{changes: changes} ->
        Enum.find_value(changes, fn
          %Ash.Resource.Change{change: {__MODULE__, opts}} -> Map.new(opts)
          _other -> nil
        end)

      _no_action ->
        nil
    end
  end
end
