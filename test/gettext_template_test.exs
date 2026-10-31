defmodule AshQuick.GettextTemplateTest do
  @moduledoc """
  What `mix ash_quick.gen.gettext` writes: AshQuick's own messages, the labels
  a host's nav and QuickViews draw, and whatever the host's own
  `mix gettext.extract` put there.
  """
  use ExUnit.Case, async: true

  alias AshQuick.Gettext.Template
  alias Expo.Message

  @nav AshQuick.Test.Nav.Declared

  defp msgids(messages), do: Enum.map(messages.messages, &IO.iodata_to_binary(&1.msgid))

  describe "labels/1" do
    test "reads the nav's entries and groups" do
      labels = Template.labels(@nav)

      # Declared, derived from a path, and a group.
      assert "Marques" in labels
      assert "Scan" in labels
      assert "Things" in labels
    end

    test "reads each QuickView's titles, and its resource's fields and actions" do
      labels = Template.labels(@nav)

      assert "Brands" in labels
      assert "Brand" in labels
      assert "Name" in labels
      assert "Index" in labels
      assert "Delete" in labels
    end

    test "reads the resources any number of relationships away, and their values" do
      labels = Template.labels(@nav)

      # Brand → Maker → Country, and Country's `one_of` regions.
      assert "Maker" in labels
      assert "Country" in labels
      assert "Region" in labels
      assert "North Africa" in labels
    end

    # The humanized name stays listed: a custom template calling
    # `Labels.name/1`, which knows no resource, still draws it.
    test "reads a label the resource declares, beside the humanized name" do
      labels = Template.labels(@nav)

      assert "VAT Number" in labels
      assert "Vat No" in labels
      assert "Premium Partner" in labels
      assert "Premium" in labels
      assert "Standard" in labels
    end

    test "lists each label once, sorted" do
      labels = Template.labels(@nav)
      assert labels == labels |> Enum.uniq() |> Enum.sort()
    end

    test "has nothing to read without a nav" do
      assert Template.labels(nil) == []
    end
  end

  describe "build/2" do
    test "starts with AshQuick's own messages, then the labels it does not have" do
      library = Expo.PO.parse_file!(Template.library_pot())
      template = Template.build(@nav)

      assert Enum.take(msgids(template), length(library.messages)) == msgids(library)
      assert "Marques" in msgids(template)
      keys = Enum.map(template.messages, &Message.key/1)
      assert keys == Enum.uniq(keys)
    end

    # The host's `mix gettext.extract` drops an autogen message no call site of
    # its own makes, and a reference into this package names nothing there.
    test "leaves AshQuick's messages unmarked and unreferenced" do
      for message <- Template.build(@nav).messages do
        refute Message.has_flag?(message, "elixir-autogen")
        assert message.references == []
      end
    end

    test "keeps the messages the host's own call sites put in its template" do
      existing = %Expo.Messages{
        messages: [
          %Message.Singular{
            msgid: ["Discount 10%"],
            flags: [["elixir-autogen", "elixir-format"]]
          },
          %Message.Singular{msgid: ["Marques"], flags: [["elixir-autogen"]]},
          %Message.Singular{msgid: ["A label nothing draws any more"]}
        ]
      }

      ids = msgids(Template.build(@nav, existing))

      assert "Discount 10%" in ids
      assert Enum.count(ids, &(&1 == "Marques")) == 1
      refute "A label nothing draws any more" in ids
    end

    # `gettext.extract` would put the host's flag and references back, and
    # `--check` would then fail on what `gettext.extract --check-up-to-date`
    # just passed.
    test "keeps the host's entry where its call site makes a label or one of AshQuick's" do
      hosts = [
        %Message.Singular{
          msgid: ["Marques"],
          flags: [["elixir-autogen"]],
          references: [{"lib/my_app_web/nav.ex", 3}]
        },
        %Message.Singular{
          msgid: ["Cancel"],
          flags: [["elixir-autogen", "elixir-format"]],
          references: [{"lib/my_app_web/live/x.ex", 9}]
        }
      ]

      messages = Template.build(@nav, %Expo.Messages{messages: hosts}).messages

      for host <- hosts do
        assert [kept] = Enum.filter(messages, &(Message.key(&1) == Message.key(host)))
        assert kept == host
      end
    end

    test "orders the messages as the host's gettext.extract does" do
      for {sort, by} <- [
            case_sensitive: & &1,
            case_insensitive: &String.downcase/1
          ] do
        ids = msgids(Template.build(@nav, nil, sort_by_msgid: sort))
        assert ids == Enum.sort_by(ids, by)
      end
    end
  end

  test "offers the Arabic seed, and nothing for a locale it has none for" do
    assert Template.seed("ar") =~ "priv/gettext_seeds/ar/LC_MESSAGES/ash_quick.po"
    assert Template.seed("xx") == nil
  end
end
