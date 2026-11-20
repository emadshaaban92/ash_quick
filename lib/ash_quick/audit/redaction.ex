defmodule AshQuick.Audit.Redaction do
  @moduledoc false
  # The `sensitive?` fields nested inside one value, found by its type rather
  # than by its shape: an embedded resource, a list of them, a union holding
  # one, a map, struct, keyword list or tuple whose `fields` constraint types
  # one, and any new type over those. `AshQuick.Audit.Change` redacts a
  # resource's own `sensitive?` attributes and arguments by name; this is the
  # same rule one level down, and the next, as far as the value goes.
  #
  # A nested field is always redacted. `record_sensitive` names the audited
  # resource's own attributes and arguments, and an embedded resource carries
  # no AshQuick extension to name its own (see `AshQuick.Info`).
  #
  # One walk serves every form a value takes on its way to the row: the cast
  # value a changeset holds (an embedded record, an `%Ash.Union{}`), the raw
  # input in its params (a map under atom or string keys, a list of embeds sent
  # as a map keyed by index), and the dumped value an entry in `changes` holds
  # (a map under atom keys, a union as its `storage` holds it). A value of a
  # type it does not know is left as it is.

  alias Ash.Resource.Info
  alias Ash.Type.NewType

  # Ash's own marker for a value it will not print (`Ash.Helpers.redact/1`).
  @redacted "**redacted**"

  @doc false
  # `value`, with every `sensitive?` field nested inside it replaced with
  # `"**redacted**"`.
  def redact(value, type, constraints), do: value |> walk(type, constraints) |> elem(0)

  @doc false
  # The values `redact/3` replaces in `value`, for what an expression may not
  # show (`AshQuick.Audit.Expression.secrets/3`).
  def secrets(value, type, constraints), do: value |> walk(type, constraints) |> elem(1)

  @doc false
  # `action`'s arguments, each one a `manage_relationship` change reads typed
  # as `{:managed, destination, type, constraints}`. Its value is walked twice:
  # by the type the argument declares, which can be an embedded input resource
  # with `sensitive?` fields of its own, and then as input to the related
  # resource — its `sensitive?` attributes, and the `sensitive?` arguments of
  # any of its actions, since which one runs is the change's to decide. One
  # level: the related resource's own managed arguments are not followed.
  def arguments(resource, action) do
    managed =
      for %Ash.Resource.Change{change: {Ash.Resource.Change.ManageRelationship, opts}} <-
            Info.action_changes(resource, action),
          destination = Info.related(resource, opts[:relationship]),
          into: %{},
          do: {opts[:argument], destination}

    for argument <- action.arguments do
      case Map.fetch(managed, argument.name) do
        {:ok, destination} ->
          type = {:managed, destination, argument.type, argument.constraints}
          %{argument | type: type, constraints: []}

        :error ->
          argument
      end
    end
  end

  defp walk(nil, _type, _constraints), do: {nil, []}

  defp walk(value, {:managed, destination, type, constraints}, _constraints) do
    {value, declared} = walk(value, type, constraints)
    {value, related} = managed(value, destination)
    {value, declared ++ related}
  end

  defp walk(value, {:managed, destination}, _constraints), do: managed(value, destination)

  defp walk(value, type, nil), do: walk(value, type, [])

  defp walk(value, type, constraints) do
    type = Ash.Type.get_type(type)

    case kind(type) do
      :array -> items(value, elem(type, 1), Keyword.get(constraints, :items, []))
      :new_type -> walk(value, NewType.subtype_of(type), NewType.constraints(type, constraints))
      :union -> union(value, constraints)
      :fielded -> fielded(value, constraints)
      :embedded -> resource(value, type)
      :other -> {value, []}
    end
  end

  defp kind({:array, _item}), do: :array
  defp kind(Ash.Type.Union), do: :union

  defp kind(type) when type in [Ash.Type.Map, Ash.Type.Struct, Ash.Type.Keyword, Ash.Type.Tuple],
    do: :fielded

  defp kind(type) when is_atom(type) do
    cond do
      NewType.new_type?(type) -> :new_type
      Info.resource?(type) and Info.embedded?(type) -> :embedded
      true -> :other
    end
  end

  defp kind(_type), do: :other

  # A list is walked item by item. A form submits a list of embeds as a map
  # keyed by index, which reaches the params that way.
  defp items(list, type, constraints) when is_list(list) do
    Enum.map_reduce(list, [], fn item, found ->
      {item, more} = walk(item, type, constraints)
      {item, more ++ found}
    end)
  end

  defp items(%{} = indexed, type, constraints) when not is_struct(indexed) do
    Enum.reduce(indexed, {indexed, []}, fn {key, item}, {indexed, found} ->
      {item, more} = walk(item, type, constraints)
      {Map.put(indexed, key, item), more ++ found}
    end)
  end

  defp items(value, _type, _constraints), do: {value, []}

  # Managed input is one item or a list of them, and a form sends the list as a
  # map keyed by index. An item that is not a map — an id, a record's primary
  # key — holds no field.
  defp managed(list, destination) when is_list(list) do
    Enum.map_reduce(list, [], fn item, found ->
      {item, more} = managed(item, destination)
      {item, more ++ found}
    end)
  end

  defp managed(%{} = value, destination) do
    if indexed?(value) do
      items(value, {:managed, destination}, [])
    else
      input(value, destination)
    end
  end

  defp managed(value, _destination), do: {value, []}

  defp indexed?(value) do
    map_size(value) > 0 and not is_struct(value) and
      Enum.all?(Map.keys(value), &(is_integer(&1) or (is_binary(&1) and &1 =~ ~r/\A\d+\z/)))
  end

  defp input(value, destination) do
    {value, found} = resource(value, destination)

    destination
    |> Info.actions()
    |> Enum.flat_map(& &1.arguments)
    |> Enum.filter(& &1.sensitive?)
    |> Enum.reduce({value, found}, &field(&2, &1.name, true, &1.type, &1.constraints))
  end

  # A cast union names its member. Anything else — raw input, or a value as
  # the store holds it — is read by the union's `storage`: `:type_and_value`
  # (the default) holds the member under `value` and names it under `type`,
  # and `:map_with_tag` is the member's own map, named by its tag field. A
  # value that names no member is walked as every member in turn, which
  # redacts a field that is sensitive in any of them.
  defp union(%Ash.Union{type: name, value: value} = union, constraints) do
    case member(Keyword.get(constraints, :types, []), name) do
      nil ->
        {union, []}

      config ->
        {value, found} = walk(value, config[:type], config[:constraints])
        {%{union | value: value}, found}
    end
  end

  defp union(%{} = value, constraints) when not is_struct(value) do
    members = Keyword.get(constraints, :types, [])

    case Keyword.get(constraints, :storage, :type_and_value) do
      :type_and_value -> type_and_value(value, members)
      :map_with_tag -> map_with_tag(value, members)
      _other -> every_member(value, members)
    end
  end

  defp union(value, constraints), do: every_member(value, Keyword.get(constraints, :types, []))

  # `%{"type" => name, "value" => value}`, under string or atom keys.
  defp type_and_value(value, members) do
    found =
      Enum.find_value([{"type", "value"}, {:type, :value}], fn {type_key, value_key} ->
        with {:ok, name} <- Map.fetch(value, type_key),
             true <- Map.has_key?(value, value_key),
             config when not is_nil(config) <- member(members, name) do
          {value_key, config}
        else
          _other -> nil
        end
      end)

    case found do
      {key, config} ->
        {inner, secrets} = walk(Map.fetch!(value, key), config[:type], config[:constraints])
        {Map.put(value, key, inner), secrets}

      _other ->
        every_member(value, members)
    end
  end

  # The member whose `tag` field holds its `tag_value`, under either key kind.
  defp map_with_tag(value, members) do
    tagged =
      Enum.find_value(members, fn {_name, config} ->
        tag = config[:tag]

        if tag && tagged?(value, tag, config[:tag_value]), do: config
      end)

    case tagged do
      nil -> every_member(value, members)
      config -> walk(value, config[:type], config[:constraints])
    end
  end

  defp tagged?(value, tag, tag_value) do
    Enum.any?([tag, to_string(tag)], fn key ->
      case Map.fetch(value, key) do
        {:ok, held} -> held == tag_value or to_string(held) == to_string(tag_value)
        :error -> false
      end
    end)
  end

  defp every_member(value, members) do
    Enum.reduce(members, {value, []}, fn {_name, config}, {value, found} ->
      {value, more} = walk(value, config[:type], config[:constraints])
      {value, more ++ found}
    end)
  end

  defp member(members, name) do
    Enum.find_value(members, fn {member, config} ->
      if member == name or to_string(member) == name, do: config
    end)
  end

  # A map, struct, keyword list or tuple typed field by field, or a struct
  # that is a resource's record. A cast keyword list holds its fields by name
  # and a cast tuple by position, in `fields` order; dumped, either is a map.
  defp fielded(value, constraints) do
    fields = constraints[:fields]

    cond do
      is_tuple(value) and fields -> tuple(value, fields)
      is_list(value) and fields -> keyword(value, fields)
      is_map(value) and fields -> map_fields(value, fields)
      is_map(value) -> instance(value, resource_struct(constraints[:instance_of]))
      true -> {value, []}
    end
  end

  defp map_fields(value, fields) do
    Enum.reduce(fields, {value, []}, fn {name, config}, acc ->
      field(acc, name, false, config[:type], config[:constraints])
    end)
  end

  defp keyword(list, fields) do
    Enum.map_reduce(list, [], fn
      {key, inner} = entry, found ->
        case fields[key] do
          nil ->
            {entry, found}

          config ->
            {inner, more} = walk(inner, config[:type], config[:constraints])
            {{key, inner}, more ++ found}
        end

      entry, found ->
        {entry, found}
    end)
  end

  defp tuple(value, fields) when tuple_size(value) == length(fields) do
    {items, found} =
      value
      |> Tuple.to_list()
      |> Enum.zip(fields)
      |> Enum.map_reduce([], fn {inner, {_name, config}}, found ->
        {inner, more} = walk(inner, config[:type], config[:constraints])
        {inner, more ++ found}
      end)

    {List.to_tuple(items), found}
  end

  defp tuple(value, _fields), do: {value, []}

  defp instance(value, nil), do: {value, []}
  defp instance(value, resource), do: resource(value, resource)

  defp resource_struct(nil), do: nil

  defp resource_struct(module) do
    if Info.resource?(module), do: module
  end

  defp resource(%{} = value, resource) do
    resource
    |> Info.attributes()
    |> Enum.reduce({value, []}, fn attribute, acc ->
      field(acc, attribute.name, attribute.sensitive?, attribute.type, attribute.constraints)
    end)
  end

  defp resource(value, _resource), do: {value, []}

  # Under whichever key kind the value uses: a record and a dumped value use
  # atoms, a form's params strings. Only a key that is there is touched, so the
  # value says nothing about a field it did not hold.
  defp field({value, found}, name, sensitive?, type, constraints) do
    Enum.reduce([name, to_string(name)], {value, found}, fn key, {value, found} ->
      case Map.fetch(value, key) do
        :error ->
          {value, found}

        {:ok, inner} when sensitive? ->
          {Map.put(value, key, @redacted), secret(inner) ++ found}

        {:ok, inner} ->
          {inner, more} = walk(inner, type, constraints)
          {Map.put(value, key, inner), more ++ found}
      end
    end)
  end

  defp secret(nil), do: []
  defp secret(%Ash.NotLoaded{}), do: []
  defp secret(%Ash.ForbiddenField{}), do: []
  defp secret(@redacted), do: []
  defp secret(value), do: [value]
end
