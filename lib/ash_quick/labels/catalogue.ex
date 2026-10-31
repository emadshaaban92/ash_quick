defmodule AshQuick.Labels.Catalogue do
  @moduledoc false
  # Which `ash_quick` messages a backend's locale translates, as
  # `{msgctxt, msgid}` pairs (`msgctxt` is `nil` for the context-free entry).
  #
  # A label is looked up with its resource's context first and without one
  # after, and Gettext offers no way to ask for a message without calling the
  # backend's `handle_missing_translation/5` when it is not there. Asking for
  # the contexted entry of every label would report nearly every label missing
  # to a host that logs those. This answers which entry to ask for, so a label
  # costs one lookup and the hook hears only of a label that is translated
  # neither way.
  #
  # Read from the same `ash_quick.po` the backend compiled, once per backend
  # version and locale: the module's md5 changes when a catalogue edit
  # recompiles it. An entry with an empty `msgstr` is not translated: Gettext
  # compiles it as missing. `:unknown` when the file cannot be found or read.

  @doc """
  The translated `{msgctxt, msgid}` pairs of `locale` in `backend`'s
  `ash_quick` domain, or `:unknown`.
  """
  def translated(backend, locale) do
    key = {__MODULE__, backend, locale}
    md5 = backend.module_info(:md5)

    case :persistent_term.get(key, nil) do
      {^md5, translated} ->
        translated

      _stale_or_none ->
        translated = read(backend, locale)
        :persistent_term.put(key, {md5, translated})
        translated
    end
  end

  defp read(backend, locale) do
    case po_file(backend, locale) do
      nil -> :unknown
      path -> read_file(path)
    end
  rescue
    _unreadable -> :unknown
  end

  @doc """
  The translated `{msgctxt, msgid}` pairs of the `.po` file at `path`.
  Raises when it cannot be read.
  """
  def read_file(path) do
    path
    |> Expo.PO.parse_file!()
    |> Map.fetch!(:messages)
    |> Enum.flat_map(&translated_key/1)
    |> MapSet.new()
  end

  defp translated_key(%Expo.Message.Singular{msgctxt: msgctxt, msgid: msgid, msgstr: msgstr}) do
    if IO.iodata_to_binary(msgstr) == "",
      do: [],
      else: [{msgctxt && IO.iodata_to_binary(msgctxt), IO.iodata_to_binary(msgid)}]
  end

  defp translated_key(_plural), do: []

  # Where the backend's `priv` is: inside its application, as a release
  # ships it, or relative to the project, as Gettext reads it at compile time.
  defp po_file(backend, locale) do
    priv = backend.__gettext__(:priv)

    [app_priv(backend.__gettext__(:otp_app), priv), priv]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.join([&1, locale, "LC_MESSAGES", "ash_quick.po"]))
    |> Enum.find(&File.regular?/1)
  end

  defp app_priv(otp_app, priv) do
    Application.app_dir(otp_app, priv)
  rescue
    ArgumentError -> nil
  end
end
