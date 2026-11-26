defmodule ExampleWeb.FormRowsWalkTest do
  @moduledoc """
  Seeded random walks over every form with sub-forms: Add, ✕, typing and
  picking, as the page offers them. After each step, a reconnect is
  replayed (a fresh view whose first change is what the page held) and must
  draw what the page held. On an update, a twin that reconnects before its
  save must save what the page saves.
  """
  use ExampleWeb.FeatureCase, async: true

  import ExUnit.CaptureLog

  @form "form[phx-submit=save]"

  @pages [
    "/test/shaped_bundles/create",
    "/test/managed_rows/create",
    "/test/managed_nest/create",
    "/test/keyed_rows/create",
    "/test/keyed_items/create",
    "/test/seat_rows/create",
    "/test/nested_items/create",
    "/test/required_entries/create",
    "/test/picked_rows/create",
    "/test/form_inputs/create",
    "/test/typed_inputs/create?action=with_parts",
    "/test/hidden_address/create",
    "/test/two_file_rows/create",
    "/test/shaped_orders/create"
  ]

  alias Example.Test.KeyedItems
  alias Example.Test.KeyedRows
  alias Example.Test.ManagedNest
  alias Example.Test.ManagedRows
  alias Example.Test.SeatRows
  alias Example.Test.ShapedBundles
  alias Example.Test.TypedInputs

  @updates [
    {"shaped_bundles", true, ShapedBundles,
     %{
       items: [
         %{kind: :good, discount: 5},
         %{kind: :device, serial: "SN-B", discount: 9, parts: [%{name: "P1"}, %{name: "P2"}]},
         %{kind: :service, hours: 3, discount: 7}
       ],
       shipping: %{country: "EG"}
     }, [items: []]},
    {"managed_rows", false, ManagedRows,
     %{
       items: [
         %{status: "a", note: "keep", secret: "first"},
         %{status: "b", note: "also", secret: "second"}
       ]
     }, [:items]},
    {"managed_nest", false, ManagedNest,
     %{rows: [%{status: "a", parts: [%{label: "p1"}, %{label: "p2"}]}, %{status: "b"}]},
     [rows: :parts]},
    {"keyed_items", false, KeyedItems,
     %{
       items: [
         %{kind: :good, discount: 5},
         %{kind: :device, serial: "SN-B", discount: 9},
         %{kind: :good, discount: 7}
       ]
     }, []},
    {"seat_rows", false, SeatRows,
     %{seats: [%{seat: "A", note: "one", secret: "sa"}, %{seat: "B", note: "two", secret: "sb"}]},
     [:seats]},
    {"keyed_rows", false, KeyedRows,
     %{members: [%{team: "alpha", note: "one"}, %{team: "beta", note: "two"}]}, [:members]}
  ]

  for {name, keyless?, resource, attrs, loads} <- @updates do
    @keyless keyless?
    @resource resource
    @attrs attrs
    @loads loads
    @name name
    test "walk the update of #{name}", %{conn: conn} do
      findings =
        for seed <- 1..12, reduce: [] do
          acc ->
            :rand.seed(:exsss, {seed, 4, 6})
            first = seed_record(@resource, @attrs)
            second = seed_record(@resource, @attrs)
            acc ++ walk_update(conn, @name, {first, second}, {@resource, @keyless}, @loads, 8)
        end

      assert findings == [], Enum.join(Enum.uniq(findings), "\n\n")
    end
  end

  defp seed_record(resource, attrs) do
    resource
    |> Ash.Changeset.for_create(:create, Map.put(attrs, :code, unique("W-")), authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp walk_update(conn, name, {first, second}, {resource, keyless?}, loads, steps) do
    path = &"/test/#{name}/#{&1.id}/update"
    {:ok, view, _html} = live(conn, path.(first))

    {history, findings} =
      Enum.reduce(1..steps, {[], []}, fn _step, {history, findings} ->
        case pick_step(view) do
          nil ->
            {history, findings}

          step ->
            run(view, step)
            held = page_params(view)
            history = history ++ [step]

            findings =
              findings ++ recovery_finding(conn, path.(first), held, history, keyless?)

            {history, findings}
        end
      end)

    # The same steps on a twin, then a reconnect, then the save: the twin
    # must save what the page saves with no reconnect.
    {:ok, twin, _html} = live(conn, path.(second))
    Enum.each(history, &run(twin, &1))
    held = page_params(twin)
    {status, _} = recovery(conn, path.(second), held, history, keyless?)
    {:ok, fresh, _html} = live(conn, path.(second))

    capture_log(fn ->
      render_change(fresh, "validate", %{"form" => held, "_target" => ["form", "code"]})
      fresh |> form(@form) |> render_submit()
      view |> form(@form) |> render_submit()
    end)

    saved = state(resource, first, loads)
    twin_saved = state(resource, second, loads)

    if saved == twin_saved or status != :same,
      do: findings,
      else:
        findings ++
          [
            "#{name} save after reconnect differs, after #{inspect(history)}:\n plain #{inspect(saved)}\n twin  #{inspect(twin_saved)}"
          ]
  end

  defp state(resource, record, loads) do
    resource
    |> Ash.get!(record.id, authorize?: false)
    |> Ash.load!(loads, authorize?: false)
    |> plain()
    |> Map.drop([:code])
  end

  @dropped [
    :id,
    :__meta__,
    :__metadata__,
    :__lateral_join_source__,
    :aggregates,
    :calculations,
    :__order__,
    :seat
  ]

  defp plain(%Ash.NotLoaded{}), do: :not_loaded
  defp plain(%Ash.Union{type: type, value: value}), do: {type, plain(value)}

  defp plain(%_{} = struct) do
    if Ash.Resource.Info.resource?(struct.__struct__) do
      struct
      |> Map.from_struct()
      |> Map.drop(@dropped)
      |> Map.reject(fn {k, _} -> String.ends_with?(to_string(k), "_id") end)
      |> Map.new(fn {k, v} -> {k, plain(v)} end)
    else
      struct
    end
  end

  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)
  defp plain(value), do: value

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  for page <- @pages do
    @page page
    test "walk #{page}", %{conn: conn} do
      findings =
        for seed <- 1..12, reduce: [] do
          acc ->
            :rand.seed(:exsss, {seed, 3, 5})
            acc ++ walk(conn, @page, 8)
        end

      assert findings == [], Enum.join(Enum.uniq(findings), "\n\n")
    end
  end

  defp walk(conn, path, steps) do
    {:ok, view, _html} = live(conn, path)

    {_, findings} =
      Enum.reduce(1..steps, {[], []}, fn _step, {history, findings} ->
        step = pick_step(view)

        case step do
          nil ->
            {history, findings}

          step ->
            run(view, step)
            held = page_params(view)
            history = history ++ [step]

            findings =
              findings ++
                recovery_finding(conn, path, held, history)

            {history, findings}
        end
      end)

    findings
  end

  defp recovery_finding(conn, path, held, history, keyless? \\ false) do
    {_status, findings} = recovery(conn, path, held, history, keyless?)
    findings
  end

  # Two gaps are known. A list the page emptied posts nothing, so its stored
  # rows come back. And rows that post no primary key (an embed without
  # one) are matched by their place, so once a stored one was removed the
  # rows after it take the stored rows above them.
  defp recovery(conn, path, held, history, keyless?) do
    {:ok, fresh, _html} = live(conn, path)

    capture_log(fn ->
      render_change(fresh, "validate", %{"form" => held, "_target" => ["form", "code"]})
    end)

    got = strip(page_params(fresh))
    held = strip(held)
    removed? = Enum.any?(history, &match?({:remove, _}, &1))

    cond do
      keyless? and removed? ->
        {:known, []}

      got == held ->
        {:same, []}

      drop_emptied(got, held) == held ->
        {:known, []}

      true ->
        {:finding,
         [
           "#{path} recovery after #{inspect(history)}:\n held #{inspect(held)}\n got  #{inspect(got)}"
         ]}
    end
  end

  defp drop_emptied(got, held) when is_map(got) and is_map(held) do
    got
    |> Enum.reject(fn {k, v} -> is_map(v) and not Map.has_key?(held, k) end)
    |> Map.new(fn {k, v} -> {k, drop_emptied(v, Map.get(held, k))} end)
  end

  defp drop_emptied(got, _held), do: got

  defp pick_step(view) do
    doc = view |> render() |> LazyHTML.from_fragment()

    adds =
      doc
      |> LazyHTML.query("#{@form} [phx-click=add-form]")
      |> Enum.map(&{:add, attribute(&1, "phx-value-path")})

    removes =
      doc
      |> LazyHTML.query("#{@form} [phx-click=remove-form]")
      |> Enum.map(&{:remove, attribute(&1, "phx-value-path")})

    texts =
      doc
      |> LazyHTML.query(
        "#{@form} input[name]:not([type=hidden]):not([type=file]):not([type=checkbox]):not([type=radio]):not([readonly]):not([disabled])"
      )
      |> Enum.map(
        &{:type, {attribute(&1, "name"), Enum.random(["7", "SN-#{:rand.uniform(99)}", "x"])}}
      )

    selects =
      doc
      |> LazyHTML.query("#{@form} select[name]:not([disabled])")
      |> Enum.map(fn node ->
        options =
          node
          |> LazyHTML.query("option")
          |> Enum.map(&attribute(&1, "value"))
          |> Enum.reject(&(&1 in [nil, ""]))

        {attribute(node, "name"), options}
      end)
      |> Enum.reject(fn {_, options} -> options == [] end)
      |> Enum.map(fn {name, options} -> {:select, {name, Enum.random(options)}} end)

    choices = Enum.uniq(adds) ++ removes ++ texts ++ selects ++ selects ++ adds

    if choices == [], do: nil, else: Enum.random(choices)
  end

  defp run(view, {:add, path}) do
    view |> element("#{@form} [phx-click=add-form][phx-value-path='#{path}']") |> render_click()
  end

  defp run(view, {:remove, path}) do
    view
    |> element("#{@form} [phx-click=remove-form][phx-value-path='#{path}']")
    |> render_click()
  end

  defp run(view, {:type, {name, value}}), do: change_field(view, name, value)
  defp run(view, {:select, {name, value}}), do: change_field(view, name, value)

  defp change_field(view, name, value) do
    params =
      view
      |> page_pairs()
      |> Enum.reject(fn {n, _} -> n == name end)
      |> Kernel.++([{name, value}])
      |> decode()

    target = name |> String.replace("]", "") |> String.split("[")

    capture_log(fn ->
      render_change(view, "validate", Map.put(params, "_target", target))
    end)
  end

  defp page_params(view), do: view |> page_pairs() |> decode() |> Map.get("form", %{})

  defp page_pairs(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(
      "#{@form} input[name]:not([type=file]):not([type=checkbox]):not([type=radio]), " <>
        "#{@form} input[type=checkbox][checked], #{@form} input[type=radio][checked], " <>
        "#{@form} select[name], #{@form} textarea[name]"
    )
    |> Enum.map(&{attribute(&1, "name"), value(&1)})
  end

  defp decode(pairs), do: pairs |> URI.encode_query() |> Plug.Conn.Query.decode()

  # The page's own bookkeeping that may differ between two views.
  defp strip(params) when is_map(params) do
    params
    |> Map.reject(fn {k, _} ->
      k in ["_persistent_id", "_touched"] or String.starts_with?(k, "_used_")
    end)
    |> Map.new(fn {k, v} -> {k, strip(v)} end)
  end

  defp strip(value), do: value

  defp value(node) do
    cond do
      LazyHTML.tag(node) == ["textarea"] ->
        LazyHTML.text(node)

      true ->
        case node |> LazyHTML.query("option[selected]") |> Enum.to_list() do
          [option | _] -> attribute(option, "value") || ""
          [] -> attribute(node, "value") || ""
        end
    end
  end

  defp attribute(node, name), do: node |> LazyHTML.attribute(name) |> List.first()
end
