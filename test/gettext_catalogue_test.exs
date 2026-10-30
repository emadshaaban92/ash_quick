defmodule AshQuick.GettextCatalogueTest do
  # CI's `mix gettext.extract --check-up-to-date` holds the .pot to the code.
  # This holds each seed a host can start from to the .pot: a message nobody
  # merged, left empty, or that `gettext.merge` matched to a different one and
  # marked fuzzy shows the wrong words, or English, with CI green otherwise.
  use ExUnit.Case, async: true

  alias Expo.Message

  @dir Path.expand("../priv/gettext_seeds", __DIR__)
  @pot Path.expand("../priv/gettext/ash_quick.pot", __DIR__)
  @locales @dir |> Path.join("*/LC_MESSAGES/ash_quick.po") |> Path.wildcard()

  test "ships at least one seed" do
    assert [_ | _] = Path.wildcard(Path.join(@dir, "*/LC_MESSAGES/ash_quick.po"))
  end

  for po <- @locales do
    @po po
    @locale po |> Path.relative_to(@dir) |> Path.split() |> hd()

    describe "#{@locale}" do
      test "has every message the .pot has" do
        missing = keys(Expo.PO.parse_file!(@pot)) -- keys(Expo.PO.parse_file!(@po))

        assert missing == [],
               "#{@locale} lacks #{inspect(missing)}; run `mix gettext.merge priv/gettext_seeds/#{@locale}/LC_MESSAGES/ash_quick.po priv/gettext/ash_quick.pot`"
      end

      test "translates every message, in every plural form" do
        untranslated =
          for message <- messages(@po),
              Enum.any?(strings(message), &(&1 == "")),
              do: Message.key(message)

        assert untranslated == [], "#{@locale} leaves #{inspect(untranslated)} empty"
      end

      test "has no fuzzy message" do
        fuzzy =
          for message <- messages(@po),
              Message.has_flag?(message, "fuzzy"),
              do: Message.key(message)

        assert fuzzy == [],
               "#{@locale} marks #{inspect(fuzzy)} fuzzy: check the translation, then drop the flag"
      end

      test "gives each plural message every form the locale has" do
        nplurals =
          @po |> Expo.PO.parse_file!() |> Expo.Messages.get_header("Plural-Forms") |> nplurals()

        short =
          for %Message.Plural{} = message <- messages(@po),
              map_size(message.msgstr) != nplurals,
              do: Message.key(message)

        assert short == [], "#{@locale} has #{nplurals} plural forms; #{inspect(short)} do not"
      end

      test "names no binding the English does not" do
        stray =
          for message <- messages(@po),
              extra = bindings(strings(message)) -- allowed(message),
              extra != [],
              do: {Message.key(message), extra}

        assert stray == [], "#{@locale} uses bindings it is never given: #{inspect(stray)}"
      end
    end
  end

  defp messages(path), do: Expo.PO.parse_file!(path).messages

  defp keys(%Expo.Messages{messages: messages}),
    do: messages |> Enum.map(&Message.key/1) |> Enum.sort()

  defp strings(%Message.Singular{msgstr: msgstr}), do: [IO.iodata_to_binary(msgstr)]

  defp strings(%Message.Plural{msgstr: msgstr}),
    do: msgstr |> Map.values() |> Enum.map(&IO.iodata_to_binary/1)

  defp msgids(%Message.Singular{msgid: msgid}), do: [IO.iodata_to_binary(msgid)]

  defp msgids(%Message.Plural{msgid: msgid, msgid_plural: plural}),
    do: [IO.iodata_to_binary(msgid), IO.iodata_to_binary(plural)]

  # Gettext passes `count` to a plural message only.
  defp allowed(%Message.Plural{} = message), do: ["count" | bindings(msgids(message))]
  defp allowed(message), do: bindings(msgids(message))

  defp bindings(strings) do
    strings
    |> Enum.flat_map(&Regex.scan(~r/%\{(\w+)\}/, &1, capture: :all_but_first))
    |> Enum.map(fn [name] -> name end)
    |> Enum.uniq()
  end

  defp nplurals([header]), do: Expo.PluralForms.parse!(header).nplurals
  defp nplurals(other), do: flunk("no single Plural-Forms header: #{inspect(other)}")
end
