defmodule ExampleWeb.RandomFormPostsTest do
  @moduledoc """
  Hand-made posts of random shapes on a nested update form: rows under any
  key, left out or brought in, sub-form rows of their own, AshPhoenix's
  `_add_`, `_drop_` and `_sort_` keys, and sub-forms left out or posted
  empty while counted as touched, as a change and then the page's save,
  or as a save. Whatever the post, the page stays up, and no row ends up
  with a discount it did not hold: the discount is read-only on a retail
  bundle (`Example.Test.ShapedBundlesLive.Quick`).
  """
  use ExampleWeb.FeatureCase, async: true

  import ExUnit.CaptureLog
  require Ash.Query

  alias Example.Test.ShapedBundles

  # Two parts on the device, so a row posted without its parts key would
  # blank a part's name.
  @stored [
    %{
      kind: :device,
      serial: "SN-A",
      discount: 5,
      parts: [%{name: "pa"}, %{name: "pb"}],
      spec: %{watts: 5}
    },
    %{kind: :good, discount: 9},
    %{kind: :service, hours: 3, discount: 7}
  ]

  @held_discounts [nil, 5, 9, 7]

  setup %{conn: conn, admin: admin} do
    {:ok, conn: log_in(conn, admin)}
  end

  test "never change a held value", %{conn: conn} do
    :rand.seed(:exsss, {7, 8, 9})

    for run <- 1..120 do
      record = Ash.create!(ShapedBundles, %{code: unique("R"), items: @stored}, authorize?: false)
      params = random_post(run)

      capture_log(fn ->
        {:ok, view, _html} = live(conn, "/test/shaped_bundles/#{record.id}/update")

        if rem(run, 2) == 0 do
          render_change(view, "validate", %{"form" => params, "_target" => ["form", "items"]})
          view |> form("form[phx-submit=save]") |> render_submit()
        else
          render_submit(view, "save", %{"form" => params})
        end
      end)

      saved =
        ShapedBundles
        |> Ash.Query.filter(id == ^record.id)
        |> Ash.read_one!(authorize?: false)

      for item <- saved.items,
          do: assert(item.discount in @held_discounts, "run #{run}: #{inspect(params)}")
    end
  end

  defp random_post(run) do
    keys = Enum.take_random(~w(0 1 2 3 5 01 02), Enum.random(0..4))

    rows =
      Map.new(keys, fn key ->
        kind = Enum.random(~w(good device service))
        row = %{"kind" => kind, "discount" => "#{100 + run}"}

        row =
          case kind do
            "device" ->
              parts = Enum.random([%{}, %{"0" => %{"name" => "p"}}, %{"1" => %{"name" => "q"}}])
              Map.merge(row, %{"serial" => "SN-#{key}", "parts" => parts})

            "service" ->
              Map.put(row, "hours", "4")

            "good" ->
              row
          end

        {key, row}
      end)

    params =
      Enum.random([
        %{"items" => rows},
        %{"items" => rows, "shipping" => Enum.random(["", %{"country" => "US"}])},
        %{"_touched" => Enum.random(["items", "shipping", "items,shipping"])},
        %{"items" => rows, "_touched" => "items,shipping"}
      ])

    case Enum.random(1..5) do
      1 -> Map.put(params, "_drop_items", Enum.take_random(~w(0 1 2 3), Enum.random(1..2)))
      2 -> Map.put(params, "_sort_items", ~w(0 1 2) |> Enum.shuffle() |> Enum.take(3))
      3 -> Map.put(params, "_add_items", Enum.random(~w(start end 1)))
      _ -> params
    end
  end
end
