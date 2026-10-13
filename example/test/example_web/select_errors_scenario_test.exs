defmodule ExampleWeb.SelectErrorsScenarioTest do
  @moduledoc """
  The select widgets follow the same rule as `input/1`: a field's error shows
  once the person used it or the form was submitted, not while something else
  on the form changes.

  `Example.Test.RequiredPicks.create` needs a relationship, an atom and an
  array of atoms, each drawn by a widget of its own rather than `input/1`.
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.{RequiredAttachments, RequiredPicks}

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  @fields [owner_id: "is required", kind: "is required", tags: "pick at least one"]

  test "stay quiet while another field changes, and say why a save failed", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/test/required_picks/create")

    for {field, _message} <- @fields, do: assert(errors(view, field) == [])

    view |> form("form[phx-submit=save]") |> render_change(%{"form" => %{"code" => unique("P")}})

    for {field, _message} <- @fields,
        do: assert(errors(view, field) == [], "#{field} spoke early")

    view
    |> form("form[phx-submit=save]", %{"form" => %{"code" => unique("P")}})
    |> render_submit()

    for {field, message} <- @fields, do: assert(errors(view, field) == [message])
  end

  # A cleared select posts the same blank as one never touched. What tells
  # them apart is the change event LiveSelect fires from the field's own hidden
  # input, so each step here posts the `_target` the browser would.
  test "say what is missing once a pick is taken back, and keep saying it", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/test/required_picks/create")
    owner = Ash.create!(RequiredAttachments, %{code: unique("R"), name: "Owner"})

    change(view, %{"owner_id" => owner.id}, "owner_id")
    change(view, %{"kind" => "small"}, "kind")
    change(view, %{"tags" => ["red"]}, "tags")

    for {field, _message} <- @fields, do: assert(errors(view, field) == [])

    change(view, %{"owner_id" => ""}, "owner_id")
    change(view, %{"kind" => ""}, "kind")

    view
    |> page_params()
    |> Map.delete("tags")
    |> Map.put("tags_empty_selection", "")
    |> then(&push_change(view, &1, "tags_empty_selection"))

    for {field, message} <- @fields, do: assert(errors(view, field) == [message])

    # Typing elsewhere posts the marks the page now carries.
    change(view, %{"code" => unique("P")}, "code")

    for {field, message} <- @fields, do: assert(errors(view, field) == [message])
  end

  # Form recovery posts every input on the page to a freshly mounted view, with
  # the first visible input as `_target`. The mark rides along as one of them.
  test "a cleared select still says why after a reconnect", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/test/required_picks/create")

    change(view, %{"kind" => "small"}, "kind")
    change(view, %{"kind" => ""}, "kind")

    assert errors(view, :kind) == ["is required"]
    recovered = page_params(view)
    assert recovered["_used_kind"] == "true"

    {:ok, view, _html} = live(conn, "/test/required_picks/create")
    assert errors(view, :kind) == []

    push_change(view, recovered, "code")

    assert errors(view, :kind) == ["is required"]
    assert errors(view, :owner_id) == []
  end

  test "on an update form, say what is missing once a stored value is cleared", %{conn: conn} do
    record = picks()
    {:ok, view, _html} = live(conn, "/test/required_picks/#{record.id}/update")

    assert errors(view, :kind) == []
    assert errors(view, :owner_id) == []

    change(view, %{"kind" => ""}, "kind")

    assert errors(view, :kind) == ["is required"]
    assert errors(view, :owner_id) == []

    change(view, %{"owner_id" => ""}, "owner_id")

    assert errors(view, :owner_id) == ["is required"]
  end

  # The owner keeps its stored value the whole time; only the kind is changed.
  test "on an update form, a select nobody opened stays quiet until the save",
       %{conn: conn} do
    record = picks()
    {:ok, view, _html} = live(conn, "/test/required_picks/#{record.id}/update")

    change(view, %{"kind" => "large"}, "kind")

    assert errors(view, :kind) == []
    assert errors(view, :owner_id) == []

    view |> form("form[phx-submit=save]") |> render_submit()

    assert errors(view, :owner_id) == ["takes only small ones"]
    assert Ash.get!(RequiredPicks, record.id).kind == :small
  end

  defp picks do
    owner = Ash.create!(RequiredAttachments, %{code: unique("R"), name: "Owner"})

    Ash.create!(RequiredPicks, %{
      code: unique("P"),
      kind: :small,
      tags: [:red],
      owner_id: owner.id
    })
  end

  # A change to one input, posted with what the rest of the page holds.
  defp change(view, params, target) do
    view
    |> form("form[phx-submit=save]")
    |> render_change(%{"form" => params, "_target" => ["form", target]})
  end

  # A post made exactly as given. An emptied tag select drops its `tags[]`
  # inputs, which the form helper would put back while they are on the page.
  defp push_change(view, params, target) do
    render_change(view, "validate", %{"form" => params, "_target" => ["form", target]})
  end

  # What the page's form posts: every named input it renders, as the browser
  # encodes them.
  defp page_params(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("form[phx-submit=save] input[name]:not([type=file])")
    |> Enum.map(&{attribute(&1, "name"), attribute(&1, "value") || ""})
    |> URI.encode_query()
    |> Plug.Conn.Query.decode()
    |> Map.fetch!("form")
  end

  defp attribute(node, name), do: node |> LazyHTML.attribute(name) |> List.first()

  # The messages rendered beside the field's select.
  defp errors(view, field) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("div[phx-feedback-for='form[#{field}]'] p.text-error")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
