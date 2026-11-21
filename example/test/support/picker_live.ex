defmodule Example.Test.PickerLive do
  @moduledoc """
  A page over `AshQuick.LiveView.Picker` alone, before any AshQuick form
  draws it: a clearable single picker with help text and an error, a tags
  picker, and a tags picker that adds new values.

  Its options are a fixed list, so it needs no database: two cities share
  the label "Alexandria", told apart by value, and a search for text starting
  "slow" waits before answering, so a later search can overtake it. A query
  string holds the starting values (`?trip[city]=cai`) and `?locale=ar` draws
  it in Arabic, right to left. What the form last posted is drawn in
  `#posted`, its `_target` in `#target`.

  Served under a strict Content-Security-Policy (`ExampleWeb.StrictCsp`), so a
  browser run shows the picker needs no inline script or style.
  """
  use Phoenix.LiveView

  alias AshQuick.LiveView.Components.FieldHelp

  @cities [
    %{value: "cai", label: "Cairo", hint: "Egypt", ar: "القاهرة"},
    %{value: "alx_eg", label: "Alexandria", hint: "Egypt", ar: "الإسكندرية"},
    %{value: "alx_us", label: "Alexandria", hint: "Virginia", ar: "الإسكندرية"},
    %{value: "gzh", label: "Giza", hint: "Egypt", ar: "الجيزة"},
    %{value: "asw", label: "Aswan", hint: "Egypt", ar: "أسوان"},
    %{value: "ast", label: "Asyut", hint: "Egypt", ar: "أسيوط"},
    %{value: "lux", label: "Luxor", hint: "Egypt", ar: "الأقصر"},
    %{value: "prs", label: "Port Said", hint: "Egypt", ar: "بورسعيد"},
    %{value: "sue", label: "Suez", hint: "Egypt", ar: "السويس"},
    %{value: "tnt", label: "Tanta", hint: "Egypt", ar: "طنطا"},
    %{value: "man", label: "Mansoura", hint: "Egypt", ar: "المنصورة"}
  ]

  @labels ["Family", "Business", "Weekend"]

  # The list the stops picker offers before anything is typed: a page of
  # five, so it ends with "Keep typing".
  @page 5

  @impl true
  def mount(params, _session, socket) do
    locale = if params["locale"] == "ar", do: "ar", else: "en"
    Gettext.put_locale(ExampleWeb.Gettext, locale)
    trip = Map.get(params, "trip", %{})

    {:ok, assign(socket, locale: locale, posted: trip, target: nil, form: trip_form(trip))}
  end

  @impl true
  def handle_event("validate", params, socket) do
    trip = AshQuick.LiveView.FormParams.put_emptied_selections(params["trip"] || %{})

    {:noreply, assign(socket, posted: trip, target: params["_target"], form: trip_form(trip))}
  end

  def handle_event("save", params, socket),
    do: handle_event("validate", params, socket)

  defp trip_form(trip), do: to_form(trip, as: :trip)

  @impl true
  def render(assigns) do
    ar? = assigns.locale == "ar"
    city_error? = assigns.posted["city"] == ""

    assigns =
      assign(assigns,
        search_cities: fn text -> search(text, ar?, nil) end,
        search_stops: fn text -> search(text, ar?, @page) end,
        resolve: fn values -> resolve(values, ar?) end,
        search_labels: &search_labels/1,
        resolve_labels: fn values -> Enum.filter(options(@labels), &(&1.value in values)) end,
        city_error?: city_error?,
        t: &text(&1, ar?)
      )

    ~H"""
    <main dir={if @locale == "ar", do: "rtl", else: "ltr"} lang={@locale} class="p-4 sm:p-8">
      <.form
        for={@form}
        id="picker-form"
        phx-change="validate"
        phx-submit="save"
        class="grid max-w-xl gap-6"
      >
        <div>
          <label id="city-label" for={@form[:city].id} class="label mb-1">{@t.("City")}</label>
          <.live_component
            module={AshQuick.LiveView.Picker}
            id="city-picker"
            field={@form[:city]}
            mode={:single}
            clearable
            search={@search_cities}
            resolve={@resolve}
            label_id="city-label"
            placeholder={@t.("Search")}
            describedby={[FieldHelp.id(@form[:city].id), @city_error? && "city-errors"]}
            invalid={@city_error?}
          />
          <FieldHelp.help id={@form[:city].id} text={@t.("Where the trip starts.")} />
          <p :if={@city_error?} id="city-errors" class="mt-1 text-sm text-error">
            {@t.("can't be blank")}
          </p>
        </div>

        <div>
          <label id="stops-label" for={@form[:stops].id} class="label mb-1">{@t.("Stops")}</label>
          <.live_component
            module={AshQuick.LiveView.Picker}
            id="stops-picker"
            field={@form[:stops]}
            mode={:tags}
            search={@search_stops}
            resolve={@resolve}
            label_id="stops-label"
            placeholder={@t.("Search")}
          />
        </div>

        <div>
          <label id="labels-label" for={@form[:labels].id} class="label mb-1">
            {@t.("Labels")}
          </label>
          <.live_component
            module={AshQuick.LiveView.Picker}
            id="labels-picker"
            field={@form[:labels]}
            mode={:tags}
            create
            create_match={:any_case}
            size={:sm}
            search={@search_labels}
            resolve={@resolve_labels}
            label_id="labels-label"
          />
        </div>

        <button type="submit" class="btn btn-primary justify-self-start">{@t.("Save")}</button>
      </.form>

      <pre id="posted" class="mt-6 text-xs opacity-60 whitespace-pre-wrap break-all">{inspect(@posted)}</pre>
      <pre id="target" class="text-xs opacity-60 whitespace-pre-wrap break-all">{inspect(@target)}</pre>
    </main>
    """
  end

  defp search("slow" <> _ = text, ar?, limit) do
    Process.sleep(300)
    search(String.replace_prefix(text, "slow", ""), ar?, limit)
  end

  defp search(text, ar?, limit) do
    found =
      @cities
      |> Enum.filter(fn city ->
        is_nil(text) or
          Enum.any?(
            [city.label, city.ar],
            &String.contains?(String.downcase(&1), String.downcase(text))
          )
      end)
      |> Enum.map(&option(&1, ar?))

    if limit && length(found) > limit, do: {Enum.take(found, limit), :more}, else: found
  end

  defp resolve(values, ar?) do
    @cities |> Enum.filter(&(&1.value in values)) |> Enum.map(&option(&1, ar?))
  end

  defp option(city, ar?),
    do: %{value: city.value, label: if(ar?, do: city.ar, else: city.label), hint: city.hint}

  defp search_labels(nil), do: options(@labels)

  defp search_labels(text) do
    @labels
    |> Enum.filter(&String.contains?(String.downcase(&1), String.downcase(text)))
    |> options()
  end

  defp options(labels), do: Enum.map(labels, &%{value: &1, label: &1})

  @arabic %{
    "City" => "المدينة",
    "Stops" => "المحطات",
    "Labels" => "التصنيفات",
    "Search" => "ابحث",
    "Save" => "حفظ",
    "Where the trip starts." => "حيث تبدأ الرحلة.",
    "can't be blank" => "لا يمكن أن يكون فارغًا"
  }

  defp text(english, true), do: Map.get(@arabic, english, english)
  defp text(english, false), do: english
end

defmodule ExampleWeb.StrictCsp do
  @moduledoc """
  A Content-Security-Policy with no `'unsafe-inline'` anywhere, for the test
  pages that show AshQuick needs none: no inline script, handler or style.
  """
  @behaviour Plug

  @policy "default-src 'self'; script-src 'self'; style-src 'self'; " <>
            "img-src 'self' data:; connect-src 'self'; object-src 'none'; " <>
            "base-uri 'self'; frame-ancestors 'none'"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts),
    do: Plug.Conn.put_resp_header(conn, "content-security-policy", @policy)
end
