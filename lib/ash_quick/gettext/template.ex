defmodule AshQuick.Gettext.Template do
  @moduledoc false
  # What `mix ash_quick.gen.gettext` writes: AshQuick's own messages, then
  # every label the host's pages can draw.
  #
  # Labels are not `gettext` call sites, so `mix gettext.extract` never sees
  # them. They are read here off what draws them: the nav, and each QuickView
  # the nav's router serves, with its resource and every resource its public
  # relationships reach (a related column, a nested form, however deep). Each is spelled the
  # way `AshQuick.Labels` spells it before translating, so the msgids match.
  # A label nothing draws is only an entry nobody reads; a label missing here
  # is drawn in English, so the walk errs towards listing.

  alias AshQuick.Labels
  alias AshQuick.LiveView.EnumOptions
  alias AshQuick.LiveView.QuickField
  alias AshQuick.LiveView.Utils
  alias AshQuick.Nav.Info
  alias Expo.Message
  alias Expo.Messages

  @doc """
  The template: the messages of AshQuick's own `ash_quick.pot`, the labels
  `nav` draws that are not among them, then the messages `mix gettext.extract`
  put in the host's own template (`existing`) from the host's own
  `dgettext("ash_quick", …)` call sites.

  AshQuick's messages lose the `elixir-autogen` flag and their references,
  which name files in this package: `mix gettext.extract` in the host drops an
  autogen message that no call site of the host's makes, and keeps the rest.
  Where a host's call site makes the same message as AshQuick or a label, the
  host's entry is kept, flag and references, since `gettext.extract` would put
  them back.

  `:sort_by_msgid` orders the messages the way the host's `gettext.extract`
  does under the same option (`:case_sensitive` or `:case_insensitive`), so
  neither undoes the other.
  """
  def build(nav, existing \\ nil, opts \\ []) do
    %Messages{} = library = Expo.PO.parse_file!(library_pot())

    hosts =
      for %{messages: messages} <- List.wrap(existing),
          message <- messages,
          Message.has_flag?(message, "elixir-autogen"),
          do: message

    by_key = Map.new(hosts, &{Message.key(&1), &1})

    own = Enum.map(library.messages, &unmark/1)
    own_keys = MapSet.new(own, &Message.key/1)

    labels =
      for label <- labels(nav),
          not MapSet.member?(own_keys, {"", label}),
          do: %Message.Singular{msgid: [label]}

    ours = own ++ labels
    ours_keys = MapSet.new(ours, &Message.key/1)

    messages =
      Enum.map(ours, &Map.get(by_key, Message.key(&1), &1)) ++
        Enum.reject(hosts, &MapSet.member?(ours_keys, Message.key(&1)))

    %Messages{library | messages: sort(messages, opts[:sort_by_msgid])}
  end

  defp sort(messages, :case_sensitive),
    do: Enum.sort_by(messages, &IO.chardata_to_string(&1.msgid))

  defp sort(messages, :case_insensitive),
    do: Enum.sort_by(messages, &String.downcase(IO.chardata_to_string(&1.msgid)))

  defp sort(messages, _unsorted), do: messages

  defp unmark(message) do
    flags = Enum.map(message.flags, &List.delete(&1, "elixir-autogen"))
    %{message | flags: flags, references: []}
  end

  @doc "AshQuick's own template, inside this package."
  def library_pot, do: Application.app_dir(:ash_quick, "priv/gettext/ash_quick.pot")

  @doc "The seed this package offers for `locale`, or `nil` when there is none."
  def seed(locale) do
    path =
      Application.app_dir(:ash_quick, "priv/gettext_seeds/#{locale}/LC_MESSAGES/ash_quick.po")

    if File.exists?(path), do: path
  end

  @doc """
  Every label `nav` and the QuickViews its router serves can draw, in English,
  sorted and without duplicates.
  """
  def labels(nil), do: []

  def labels(nav) do
    router = Info.router(nav)
    views = quick_views(router)

    resources = views |> Enum.map(& &1.resource) |> reachable()

    [
      Enum.map(Info.entries(nav, router), & &1.label),
      Enum.map(Info.groups(nav), & &1.label),
      Enum.flat_map(views, &view_labels/1),
      Enum.flat_map(resources, &resource_labels/1)
    ]
    |> List.flatten()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp quick_views(nil), do: []

  defp quick_views(router) do
    router
    |> Phoenix.Router.routes()
    |> Enum.flat_map(fn
      %{metadata: %{ash_quick: _, phoenix_live_view: {view, _, _, _}}} -> [view]
      _route -> []
    end)
    |> Enum.uniq()
    |> Enum.filter(
      &(Code.ensure_loaded?(&1) and function_exported?(&1, :__ash_quick_options__, 0))
    )
    |> Enum.map(& &1.__ash_quick_options__())
  end

  # A QuickView's own words: its titles, columns, rows, export headers, the
  # New button, saved filters and bulk items.
  defp view_labels(options) do
    resource = options.resource
    short_name = Ash.Resource.Info.short_name(resource)

    [
      Utils.humanize(Ash.Resource.Info.plural_name(resource) || "#{short_name}s"),
      Utils.humanize(short_name),
      Enum.map(options.list_fields ++ options.details_fields ++ options.export_fields, &field/1),
      options.new_action_label,
      Enum.map(List.wrap(options.filters), &(&1["label"] || &1[:label])),
      bulk_labels(options.bulk_actions, resource)
    ]
  end

  defp field(%QuickField{label: label}), do: label
  defp field(field), do: field |> QuickField.normalize() |> field()

  defp bulk_labels(items, resource) when is_list(items) do
    Enum.map(items, fn
      %{title: title} -> title
      name when is_atom(name) and name not in [nil, false] -> Labels.english(name, resource)
      _item -> nil
    end)
  end

  defp bulk_labels(_items_from_a_function, _resource), do: []

  # What a resource names: its fields, its actions and their inputs, and the
  # values any of them picks from, each as the resource labels it.
  defp resource_labels(resource) do
    fields =
      Ash.Resource.Info.public_attributes(resource) ++
        Ash.Resource.Info.public_calculations(resource) ++
        Ash.Resource.Info.public_aggregates(resource)

    relationships = Ash.Resource.Info.public_relationships(resource)
    actions = Ash.Resource.Info.public_actions(resource)
    inputs = Enum.flat_map(actions, &Utils.action_fields(resource, &1.name))

    [
      Enum.map(fields ++ relationships ++ inputs ++ actions, &Labels.english(&1.name, resource)),
      Enum.map(fields ++ inputs, &values(&1, resource))
    ]
  end

  defp values(field, resource),
    do: field |> EnumOptions.english_options(resource) |> Enum.map(&elem(&1, 0))

  # Every resource a public relationship path leads to from `resources`, those
  # included: a column or a nested form can be any number of hops away.
  defp reachable(resources), do: reachable(resources, MapSet.new())

  defp reachable([], seen), do: MapSet.to_list(seen)

  defp reachable([resource | rest], seen) do
    if MapSet.member?(seen, resource) do
      reachable(rest, seen)
    else
      next =
        resource
        |> Ash.Resource.Info.public_relationships()
        |> Enum.map(& &1.destination)

      reachable(next ++ rest, MapSet.put(seen, resource))
    end
  end
end
