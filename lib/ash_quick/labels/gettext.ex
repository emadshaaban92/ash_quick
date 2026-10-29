defmodule AshQuick.Labels.Gettext do
  @moduledoc false
  # The `gettext` calls a QuickView is given as it compiles, one per label it
  # can draw, so `mix gettext.extract` in the host finds them in the
  # `:label_gettext_backend`'s `labels` domain, as it finds the host's own.

  @domain "labels"

  @doc """
  A function holding a `dgettext_noop` call for each of `labels`, or nothing
  without a `:label_gettext_backend`. The calls are on `line`, so a reference
  in the template points at the `use` that brought them.
  """
  def calls(labels, line \\ 1) do
    case noops(labels, line) do
      [] ->
        nil

      calls ->
        quote do
          require Gettext.Macros

          @doc false
          def __ash_quick_labels__, do: unquote(calls)
        end
    end
  end

  @doc """
  The `dgettext_noop` calls for `labels` on `line`, each expanding to its
  label, or none without a `:label_gettext_backend`. The caller requires
  `Gettext.Macros`.
  """
  def noops(labels, line) do
    case AshQuick.Config.label_gettext_backend() do
      nil ->
        []

      backend ->
        for label <- labels do
          quote line: line do
            Gettext.Macros.dgettext_noop_with_backend(
              unquote(backend),
              unquote(@domain),
              unquote(label)
            )
          end
        end
    end
  end
end
