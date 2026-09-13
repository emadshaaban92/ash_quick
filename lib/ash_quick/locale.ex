defmodule AshQuick.Locale do
  @moduledoc """
  What a locale means for the markup around it.

  The locale itself is Gettext's — set once per process from the scope, read
  back with `Gettext.get_locale/0`. This answers the one thing Gettext does not:
  which way the page runs, for the `dir` attribute the whole layout keys off.

  Directional CSS is written with logical properties, so `dir` is the only
  switch: set it on `<html>` and the sidebar, tables and forms follow, as do
  daisyUI's own components.
  """

  # Every language written right-to-left that this stack can render. Membership
  # is a property of the script, not of who happens to be translated today, so
  # a locale arriving before its catalogue still lays out correctly.
  @rtl ~w(ar arc ckb dv fa he ks ku ps sd ug ur yi)

  @doc """
  `"rtl"` or `"ltr"` for the process's current locale.
  """
  def direction, do: Gettext.get_locale() |> direction()

  @doc """
  `"rtl"` or `"ltr"` for `locale`, ignoring any region suffix — `"ar_EG"` is as
  right-to-left as `"ar"`.
  """
  def direction(locale) when is_binary(locale) do
    case rtl?(locale) do
      true -> "rtl"
      false -> "ltr"
    end
  end

  @doc """
  Whether `locale` is written right-to-left.
  """
  def rtl?(locale) when is_binary(locale) do
    locale |> String.split(["_", "-"]) |> hd() |> String.downcase() |> Kernel.in(@rtl)
  end
end
