defmodule AshQuick.LiveView.BulkActions do
  @moduledoc false
  # The list's bulk menu: what `list: [bulk_actions: ...]` names, or what is
  # derived from the resource when it names nothing.

  alias AshQuick.LiveView.QuickView.Options
  alias AshQuick.LiveView.Utils
  alias Phoenix.LiveView.JS

  @doc """
  The menu for this socket's actor.

  Named actions are probed under `:ash_quick_list_bulk`, so a page lists the
  actions it wants and the policies decide who sees each one.
  """
  def menu(%Options{bulk_actions: nil} = options, socket) do
    derived(options.resource, socket.assigns.scope)
  end

  def menu(%Options{bulk_actions: fun} = options, socket) when is_function(fun, 1) do
    case fun.(socket) do
      items when is_list(items) ->
        items |> check!(options.resource, options.module) |> resolve(options.resource, socket)

      other ->
        raise ArgumentError, """
        #{inspect(options.module)}'s `list: [bulk_actions: ...]` function returned \
        #{inspect(other)}. It must return a list of action names and custom items \
        (%{title: ..., func: ...} or %{title: ..., link: ...}).
        """
    end
  end

  def menu(%Options{bulk_actions: items} = options, socket) when is_list(items) do
    resolve(items, options.resource, socket)
  end

  @doc """
  Every public update and destroy that takes no input, as the actor may run it.

  One that takes input is never derived: whether one set of values makes sense
  for every selected row is the page's call, so the page names it.
  """
  def derived(resource, scope) do
    resource
    |> Utils.record_actions()
    |> Enum.filter(&Enum.empty?(Ash.Resource.Info.action_inputs(resource, &1.name)))
    |> Enum.map(& &1.name)
    |> Enum.filter(&offerable?(resource, &1, scope))
    |> Enum.map(&item/1)
  end

  @doc "The action a `\"bulk_action\"` event names, if the menu offered it."
  def offered(menu, resource, name) when is_binary(name) do
    menu
    |> List.wrap()
    |> Enum.find_value(fn
      %{ash_quick_action: action_name} -> Atom.to_string(action_name) == name && action_name
      _custom -> nil
    end)
    |> case do
      nil -> nil
      action_name -> Ash.Resource.Info.action(resource, action_name)
    end
  end

  def offered(_menu, _resource, _name), do: nil

  @doc """
  Raises unless every action name in `items` is one a bulk menu can run.

  `module` is the QuickView, which every message names: the list is written
  there, and it is the file to change.
  """
  def check!(items, resource, module) do
    Enum.each(items, &check_item!(&1, resource, module))
    items
  end

  # Falsy entries are skipped, so a page can write `if admin?, do: :reprice`.
  defp check_item!(item, _resource, _module) when item in [nil, false], do: :ok
  defp check_item!(item, _resource, _module) when is_map(item), do: :ok

  defp check_item!(name, resource, module) when is_atom(name) do
    case Ash.Resource.Info.action(resource, name) do
      nil ->
        refuse!(module, name, """
        #{inspect(resource)} has no action named #{inspect(name)}. Check the \
        spelling, or add the action to the resource.\
        """)

      %{type: type} when type not in [:update, :destroy] ->
        refuse!(module, name, """
        #{inspect(name)} is a #{type} action, and only an update or a destroy acts \
        on the selected rows. Remove it from the list, or run it from a custom item \
        (%{title: ..., func: ...}) that handles its own event.\
        """)

      %{public?: false} ->
        refuse!(module, name, """
        #{inspect(name)} is private (`public? false`), and AshQuick never offers an \
        internal action on a page. Remove it from the list, or make the action public.\
        """)

      action ->
        case upload_field(resource, action) do
          nil ->
            :ok

          field ->
            refuse!(module, name, """
            #{inspect(name)} takes uploads (#{inspect(field)}). An upload belongs to one \
            record, so it cannot be applied to every selected row. Remove it from the \
            list; it is still offered on each row.\
            """)
        end
    end
  end

  defp check_item!(item, _resource, module) do
    raise ArgumentError, """
    #{inspect(module)} lists #{inspect(item)} in `list: [bulk_actions: ...]`, which is \
    neither an action name nor a custom item. Name a public update or destroy action \
    (`:archive`), or give a map: %{title: "...", func: %JS{}} or %{title: "...", link: "..."}.
    """
  end

  defp refuse!(module, name, reason) do
    raise ArgumentError, """
    #{inspect(module)} names #{inspect(name)} in `list: [bulk_actions: ...]`, which \
    cannot run over a selection: #{reason}
    """
  end

  # The fields `FormUtils` serves with `allow_upload`, at any depth an embed
  # puts them.
  defp upload_field(resource, %{name: name}) do
    resource
    |> Utils.action_fields(name)
    |> Enum.find_value(fn field ->
      uploads?(Map.get(field, :type), MapSet.new()) && field.name
    end)
  end

  defp uploads?({:array, type}, seen), do: uploads?(type, seen)
  defp uploads?(AshQuick.AshTypes.Attachment, _seen), do: true

  defp uploads?(type, seen) when is_atom(type) and not is_nil(type) do
    cond do
      MapSet.member?(seen, type) ->
        false

      Ash.Type.NewType.new_type?(type) ->
        uploads?(Ash.Type.NewType.subtype_of(type), MapSet.put(seen, type))

      Ash.Type.embedded_type?(type) ->
        type
        |> Ash.Resource.Info.public_attributes()
        |> Enum.any?(&uploads?(&1.type, MapSet.put(seen, type)))

      true ->
        false
    end
  end

  defp uploads?(_type, _seen), do: false

  defp resolve(items, resource, socket) do
    Enum.flat_map(items, fn
      item when item in [nil, false] -> []
      item when is_map(item) -> [item]
      name -> if offerable?(resource, name, socket.assigns.scope), do: [item(name)], else: []
    end)
  end

  defp offerable?(resource, name, scope) do
    AshQuick.can?({resource, name}, scope, :ash_quick_list_bulk)
  end

  defp item(name) do
    %{
      title: Utils.label(name),
      func: JS.push("bulk_action", value: %{"action_name" => Atom.to_string(name)}),
      ash_quick_action: name
    }
  end
end
