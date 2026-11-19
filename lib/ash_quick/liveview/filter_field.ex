defmodule AshQuick.LiveView.FilterField do
  @moduledoc false
  # A field a list's filter row can name: one of the list's resource, one of
  # a resource a public belongs_to relationship reaches, one hop away, or a
  # record row, which picks the related records themselves.
  #
  #   * `:name` — what a row holds and its URL carries: `"code"`, or the
  #     path joined by dots, `"brand.name"`, as a list column's
  #     `QuickField.data_field/1` names one. A record row's is its path:
  #     `"brand"`, `"tags.tag_group"`.
  #   * `:spec` — how `filterable:` names it: `:code`, `{:brand, :name}`, or
  #     a record row's `:brand` or `{:tags, :tag_group}`.
  #   * `:relationship` — the relationship it is reached through, the last
  #     hop of a record row's path, or `nil`.
  #   * `:field` — the Ash attribute, aggregate or calculation itself; a
  #     record row's is its destination's primary key, which its values are.
  #   * `:resource` — the resource holding `:field`: the list's, or the
  #     relationship's destination. Its labels name the field and its values.
  #   * `:record?` — whether the row picks records of `:resource`.
  #   * `:path` — a record row's relationships, by name, `[:tags, :tag_group]`.
  #   * `:hops` — the relationships themselves, in the same order.

  use Gettext, backend: AshQuick.Gettext

  alias AshQuick.Labels

  @enforce_keys [:name, :spec, :field, :resource]
  defstruct [:name, :spec, :relationship, :field, :resource, :path, record?: false, hops: []]

  @doc "`field`, one of `resource`'s own."
  def own(resource, field),
    do: %__MODULE__{
      name: to_string(field.name),
      spec: field.name,
      field: field,
      resource: resource
    }

  @doc "`field` of `relationship`'s destination, reached through it."
  def through(relationship, field),
    do: %__MODULE__{
      name: "#{relationship.name}.#{field.name}",
      spec: {relationship.name, field.name},
      relationship: relationship,
      field: field,
      resource: relationship.destination
    }

  @doc """
  A record row through `hops`, one relationship or two, picking records of
  the last one's destination by `key`, its primary key attribute.
  """
  def records([first | _] = hops, key) do
    last = List.last(hops)
    path = Enum.map(hops, & &1.name)

    %__MODULE__{
      name: Enum.join(path, "."),
      spec: if(length(hops) == 1, do: first.name, else: List.to_tuple(path)),
      relationship: last,
      field: key,
      resource: last.destination,
      record?: true,
      path: path,
      hops: hops
    }
  end

  @doc """
  The name a row holds for `spec`, as `filterable:` writes it: `"code"` for
  `:code`, `"brand.name"` for `{:brand, :name}`.
  """
  def name(name) when is_atom(name), do: to_string(name)
  def name({relationship, name}), do: "#{relationship}.#{name}"

  @doc """
  Whether a row's field name, as a URL carries it, names a field through a
  relationship.
  """
  def path?(name) when is_binary(name), do: String.contains?(name, ".")
  def path?(_name), do: false

  @doc """
  What a row on a path names reads as, here and on the list's chips:
  "Brand › Name", the relationship as `resource` labels it, and the field as
  the resource it reaches does. A part naming nothing of either reads as
  written, humanized.
  """
  def path_label(name, resource) when is_binary(name) do
    [relationship_name, field_name] = String.split(name, ".", parts: 2)
    relationship = known_atom(relationship_name)

    destination =
      if is_atom(relationship) and resource,
        do: resource |> Ash.Resource.Info.relationship(relationship) |> destination()

    gettext("%{relationship} › %{field}",
      relationship: Labels.name(relationship, resource),
      field: field_name |> known_atom() |> Labels.name(destination)
    )
  end

  defp destination(%{destination: destination}), do: destination
  defp destination(nil), do: nil

  @doc """
  A row's field name comes from a URL, so it is never made an atom: one a
  resource has is one already, and any other is kept as written.
  """
  def known_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> name
  end
end
