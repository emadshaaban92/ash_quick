defmodule AshQuick.LiveView.URLParamsTest do
  @moduledoc """
  What a QuickView does with a query string it was not handed by its own
  controls.

  These are the ways a URL can be wrong rather than the ways it can be right,
  and none of them asserts an error: `from_url_params/1` runs before there is a
  mounted page to show one on, so every case here asserts a value the page can
  be rendered with instead.
  """
  use ExUnit.Case, async: true

  alias AshQuick.LiveView.CustomFilter
  alias AshQuick.LiveView.QuickView
  alias AshQuick.LiveView.URLParams

  @base "/products"

  describe "limit" do
    test "a number is taken as written" do
      assert URLParams.from_url_params(%{"limit" => "50"}).limit == 50
    end

    test "absent, or anything that is not a number, is the default page" do
      for params <- [%{}, %{"limit" => "abc"}, %{"limit" => ""}, %{"limit" => "12abc"}] do
        assert URLParams.from_url_params(params).limit == 20
      end
    end

    test "a list, which is what `?limit[]=` arrives as, is the default page" do
      assert URLParams.from_url_params(%{"limit" => ["50"]}).limit == 20
    end

    test "a page larger than the configured maximum is clamped to it" do
      assert URLParams.from_url_params(%{"limit" => "100000"}).limit == 250
    end

    test "a page of nothing is a page of one" do
      for limit <- ["0", "-5"] do
        assert URLParams.from_url_params(%{"limit" => limit}).limit == 1
      end
    end
  end

  describe "page" do
    test "a number is taken as written" do
      assert URLParams.from_url_params(%{"page" => "3"}).page == 3
    end

    test "anything before the first page is the first page" do
      for params <- [
            %{},
            %{"page" => "0"},
            %{"page" => "-5"},
            %{"page" => "abc"},
            %{"page" => []}
          ] do
        assert URLParams.from_url_params(params).page == 1
      end
    end

    # An offset out of the data layer's range raised, where a page past the end
    # of the data merely lists nothing.
    test "a page deeper than any table is the deepest page there is" do
      params = URLParams.from_url_params(%{"page" => "99999999999999999999"})

      assert params.page == div(1_000_000_000, params.limit) + 1
    end

    test "the ceiling is measured in rows, so a larger page reaches it sooner" do
      deep = "99999999999999999999"

      assert URLParams.from_url_params(%{"page" => deep, "limit" => "250"}).page <
               URLParams.from_url_params(%{"page" => deep, "limit" => "20"}).page
    end

    test "a page a real table can hold is taken as written" do
      assert URLParams.from_url_params(%{"page" => "999999"}).page == 999_999
    end
  end

  describe "action" do
    test "a name something has already made an atom of becomes that atom" do
      assert URLParams.from_url_params(%{"action" => "create"}).action == :create
    end

    test "a name nothing has made an atom of stays a string, for the resource to refuse" do
      assert URLParams.from_url_params(%{"action" => "no_such_action_anywhere"}).action ==
               "no_such_action_anywhere"
    end

    test "a list is as much a missing action as no action at all" do
      assert URLParams.from_url_params(%{"action" => ["create"]}).action == nil
    end
  end

  describe "read arguments" do
    test "a declared argument is passed on under its own name" do
      assert URLParams.from_url_params(%{"arg__search" => "widget"}).read_args == %{
               search: "widget"
             }
    end

    test "a name no atom was ever made for is dropped rather than passed" do
      assert URLParams.from_url_params(%{"arg__no_such_argument_anywhere" => "1"}).read_args ==
               %{}
    end

    # `?arg__x[a]=1` and `?arg__x[]=1` arrive as a map and a list, and
    # `URI.encode_query/1` takes neither — no `String.Chars` for a map, and an
    # outright refusal for a list. Carrying either through would leave a struct
    # that cannot be written back to a path.
    test "a shape the query cannot express is as much a missing argument as none" do
      for value <- [%{"a" => "1"}, ["1"], ["1", "2"], 1] do
        params = URLParams.from_url_params(%{"arg__search" => value})

        assert params.read_args == %{}
        assert URLParams.full_path("/products", params) == "/products"
      end
    end

    test "only the prefixed keys are arguments" do
      params = %{"search" => "widget", "arg__search" => "widget"}

      assert URLParams.from_url_params(params).read_args == %{search: "widget"}
    end
  end

  describe "search and selected filters" do
    test "a string is taken as written" do
      params = URLParams.from_url_params(%{"search" => "widget", "selected_filters" => "a,b"})

      assert params.search == "widget"
      assert params.selected_filters == ["a", "b"]
    end

    test "a list is the empty search over no filters" do
      params = URLParams.from_url_params(%{"search" => ["x"], "selected_filters" => ["a"]})

      assert params.search == ""
      assert params.selected_filters == []
    end
  end

  describe "custom filter" do
    test "what the page encoded is what comes back" do
      filter = %CustomFilter{
        uuid: Ash.UUID.generate(),
        operator: "equals",
        field_name: "name",
        value: "widget"
      }

      decoded = URLParams.from_url_params(%{"custom_filter" => CustomFilter.to_string!(filter)})

      assert decoded.custom_filter.field_name == "name"
      assert decoded.custom_filter.operator == "equals"
      assert decoded.custom_filter.value == "widget"
    end

    test "a filter that does not decode is no filter, however it fails to" do
      undecodable = [
        # Not base64, in each of the shapes `:base64.decode/1` fails at
        # differently. All but the last raise something other than
        # `ArgumentError`; the last is the one that makes naming it look right.
        "0",
        "=",
        "A9B99",
        "+0",
        "/99=A",
        "A/0=B",
        "09+=+",
        "+===",
        "!!!!",
        # Base64 of something that is not JSON.
        :base64.encode("not json"),
        # JSON naming no field of the struct.
        :base64.encode(JSON.encode!(%{"no_such_key" => 1})),
        # JSON that is not a filter at all.
        :base64.encode(JSON.encode!([1, 2])),
        :base64.encode(JSON.encode!("filter"))
      ]

      for custom_filter <- undecodable do
        assert URLParams.from_url_params(%{"custom_filter" => custom_filter}).custom_filter == nil
      end
    end

    # The table above is nine shapes somebody found; this is the claim they are
    # samples of, and it fails for any rescue that decodes base64 by naming
    # exception types.
    test "no string at all decodes to a raise" do
      # Seeded, so a failure names an input that can be pasted back.
      :rand.seed(:exsss, {17, 42, 99})
      alphabet = ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/= -_"

      for _ <- 1..2_000 do
        string =
          1..:rand.uniform(8)
          |> Enum.map(fn _ -> Enum.random(alphabet) end)
          |> List.to_string()

        assert %URLParams{custom_filter: nil} =
                 URLParams.from_url_params(%{"custom_filter" => string})
      end
    end

    # A group decodes whatever its children turn out to be, so this comes back
    # as a filter rather than as nothing. What matters holds either way:
    # nothing a forged child named reaches the query.
    test "a child that is not a filter is dropped from the group it was nested in" do
      encoded = :base64.encode(JSON.encode!(%{"operator" => "and", "children" => [1, 2]}))

      decoded = URLParams.from_url_params(%{"custom_filter" => encoded}).custom_filter

      assert decoded.children == []
      assert CustomFilter.build_ash_filter(decoded) == nil
    end
  end

  describe "the path a QuickView writes back" do
    test "carries a raised limit, and leaves the default one unsaid" do
      params = URLParams.from_url_params(%{"limit" => "50"})

      assert URLParams.full_path("/products", params) == "/products?limit=50"
      assert URLParams.full_path("/products", URLParams.from_url_params(%{})) == "/products"
    end

    test "round-trips what it wrote" do
      params = URLParams.from_url_params(%{"limit" => "50", "page" => "3", "search" => "widget"})

      "/products?" <> query = URLParams.full_path("/products", params)

      assert query |> URI.decode_query() |> URLParams.from_url_params() == params
    end

    # Canonicalizing from `handle_params/3` patches whenever the query it was
    # given is not the query this writes back. Two things have to hold for that
    # to be safe, and this is the claim they add up to: either the paths agree
    # and one patch reaches a fixed point, or there is no patch at all.
    #
    # A second patch means every request patches, and every patch is a request.
    # At mount LiveView resolves a patch by re-invoking `handle_params/3` with
    # no redirect limit, so non-convergence hangs the process rather than
    # raising.
    test "one patch settles it, or there is no patch" do
      for url <- [
            "/products",
            "/products?page=2",
            "/products?limit=50&page=2",
            # Converge only after a pass, rather than at once.
            "/products?limit=abc",
            "/products?limit=100000",
            "/products?page=-5",
            "/products?custom_filter=0",
            "/products?show_custom_filter=",
            "/products?arg__no_such_argument_anywhere=1",
            "/products?foo=bar",
            # The path shapes `path_no_params/2` rebuilds.
            "/products/create",
            # `/create` takes its action from the router's `live_action`, so it
            # is the one shape carrying no path param — `full_path/2` writes the
            # bare base path for it, which is a different page.
            "/products/create?limit=abc",
            "/products/create?return_to=%2Fdashboard",
            "/products/abc-123",
            "/products/abc-123?limit=abc",
            "/products/abc-123/update",
            "/products/abc-123/update?limit=abc",
            # `?action=` names a route shape that does not exist, and an id the
            # URL percent-encodes comes back raw. Both are paths this may not
            # rewrite, so both must settle by not patching at all.
            "/products/create?action=quick_add",
            "/products/abc-123?action=update",
            "/products/a%20b",
            "/products/a%20b?limit=abc"
          ] do
        assert_settles(url)
      end
    end

    # The table above is twenty URLs chosen by hand. This is the claim they are
    # samples of, over the same seeded alphabet the custom-filter sweep uses —
    # extended with an `action` key and an id segment that needs escaping,
    # because both known breakages live there.
    test "no URL at all patches twice" do
      # Seeded, so a failure names an input that can be pasted back.
      :rand.seed(:exsss, {17, 42, 99})
      alphabet = ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/= -_"

      keys = ~w(limit page search selected_filters custom_filter show_custom_filter
                arg__search arg__no_such_argument_anywhere action foo)

      junk = fn ->
        1..:rand.uniform(8)
        |> Enum.map(fn _ -> Enum.random(alphabet) end)
        |> List.to_string()
      end

      for _ <- 1..2_000 do
        query =
          1..:rand.uniform(4)
          |> Enum.into(%{}, fn _ -> {Enum.random(keys), junk.()} end)
          |> URI.encode_query()

        # The four shapes `quick_view/3` serves. The id is escaped the way a
        # browser escapes it, which is what `full_path/2` does not undo.
        path =
          case :rand.uniform(4) do
            1 -> @base
            2 -> "#{@base}/create"
            3 -> "#{@base}/#{URI.encode_www_form(junk.())}"
            4 -> "#{@base}/#{URI.encode_www_form(junk.())}/#{URI.encode_www_form(junk.())}"
          end

        assert_settles("#{path}?#{query}")
      end
    end
  end

  # The four shapes `AshQuick.LiveView.Router.quick_view/3` serves, matched the
  # way the router matches them: path segments become params, decoded, and the
  # query is merged on top. `/products/create` carries no path param — its
  # action comes from the route's `live_action`, which no query string sets.
  defp route_params(path) do
    case path |> String.replace_prefix(@base, "") |> String.split("/", trim: true) do
      [] -> %{}
      ["create"] -> %{}
      [id] -> %{"id" => URI.decode(id)}
      [id, action] -> %{"id" => URI.decode(id), "action" => URI.decode(action)}
      other -> flunk("#{@base}/#{Enum.join(other, "/")} is not a shape quick_view/3 serves")
    end
  end

  # One pass of what `handle_params/3` does, driven by a URL rather than a bare
  # params map, because the path is half of what is being decided.
  defp canonicalize(url) do
    uri = URI.parse(url)
    raw = Map.merge(route_params(uri.path), URI.decode_query(uri.query || ""))
    canonical_path = URLParams.full_path(@base, URLParams.from_url_params(raw))

    if QuickView.correctable_query?(uri, canonical_path) do
      {:patch, canonical_path}
    else
      :no_patch
    end
  end

  defp assert_settles(url) do
    case canonicalize(url) do
      :no_patch ->
        :ok

      {:patch, once} ->
        # Correct the query, never the path. A patch that moves the page is not
        # a tidier URL, it is a navigation — `?action=` is the case that proves
        # it, since `full_path/2` writes the action into the path and lands on
        # `/:id`.
        assert URI.parse(once).path == URI.parse(url).path,
               """
               canonicalizing #{inspect(url)} moved the page:
                 served at #{inspect(URI.parse(url).path)}
                 patched to #{inspect(once)}
               """

        assert canonicalize(once) == :no_patch,
               """
               canonicalizing #{inspect(url)} never settles:
                 pass 1 patches to #{inspect(once)}
                 pass 2 patches again to #{inspect(canonicalize(once))}
               """
    end
  end
end

defmodule AshQuick.LiveView.URLParamsCeilingTest do
  @moduledoc """
  The cases that read `:max_page_size` back out of the application environment.

  Kept apart so the rest of the parse cases, which mutate nothing, stay async.
  """
  use ExUnit.Case, async: false

  alias AshQuick.LiveView.URLParams

  setup do
    Application.put_env(:ash_quick, :max_page_size, 10)
    on_exit(fn -> Application.delete_env(:ash_quick, :max_page_size) end)
  end

  test "the ceiling is the host's to set" do
    assert URLParams.from_url_params(%{"limit" => "100000"}).limit == 10
  end

  test "and the page nobody asked for a size of is held to it too" do
    assert URLParams.from_url_params(%{}).limit == 10
  end

  test "so a path leaves the limit it actually reads unsaid" do
    assert URLParams.full_path("/products", URLParams.from_url_params(%{})) == "/products"

    assert URLParams.full_path("/products", URLParams.from_url_params(%{"limit" => "20"})) ==
             "/products"
  end
end
