defmodule ExampleWeb.DeclaredLabelsScenarioTest do
  @moduledoc """
  A label a resource declares under `ash_quick do labels do ... end end` is
  drawn wherever the page names that field, action or value: list columns and
  cells, details rows, the filter and its chips, row and bulk actions, and
  forms. A QuickView's own `label:` still wins on its page.

  `Example.Test.LabelledLoans` declares one of each kind, and
  `Example.Test.LabelledLoansLive.Quick` draws them. Read in English: the
  declared label is the English the page shows, and the msgid it is
  translated under (`AshQuick.LabelsTest` in the library reads one
  translated).
  """
  use ExampleWeb.FeatureCase, async: true

  alias Example.Test.LabelledLoans
  alias Example.Test.LabelledLoans.Borrower

  setup %{conn: conn, admin: admin} do
    borrower = Ash.create!(Borrower, %{name: unique("Borrower"), national_id: "29001011234567"})

    loan =
      Ash.create!(LabelledLoans, %{
        name: unique("Loan"),
        borrower_national_id: "29001011234567",
        status: :paid_off,
        kind: :business,
        borrower_id: borrower.id
      })

    {:ok, conn: log_in(conn, admin), loan: loan}
  end

  test "the list labels its columns, values and actions", %{conn: conn, loan: loan} do
    {:ok, view, _html} = live(conn, "/test/labelled_loans?search=#{loan.name}")

    assert texts(view, "th") |> Enum.drop_while(&(&1 != "Name")) |> Enum.take(5) == [
             "Name",
             "Borrower National ID",
             "Status",
             "Kind",
             "National ID"
           ]

    cells = texts(view, "td")
    assert "Paid Off in Full" in cells
    assert "Business Loan" in cells
    refute "Paid off" in cells
    refute "Business" in cells

    view
    |> element(~s([id="#{loan.id}-row-actions-dropdown"] [role="button"]))
    |> render_click()

    assert has_element?(
             view,
             ~s([id="#{loan.id}-action-issue_bill_of_sale"]),
             "Issue Bill of Sale"
           )

    assert has_element?(view, ~s([id="#{loan.id}-action-close_out"]), "Settle Early")

    render_change(view, "table-form-change", %{loan.id => "on"})
    assert has_element?(view, "#bulk-actions-menu a", "Settle Early")
    refute has_element?(view, "#bulk-actions-menu a", "Close Out")
  end

  test "the details page labels its rows, under a QuickView's own label", ctx do
    %{conn: conn, loan: loan} = ctx

    conn
    |> visit("/test/labelled_loans/#{loan.id}")
    |> assert_has(~s([data-field="borrower_national_id"] dt),
      text: "Borrower National ID",
      exact: true
    )
    |> assert_has(~s([data-field="status"] dd), text: "Paid Off in Full", exact: true)
    |> assert_has(~s([data-field="borrower.national_id"] dt), text: "National ID", exact: true)
    |> assert_has(~s([data-field="kind"] dt), text: "Loan Type", exact: true)
    |> assert_has(~s([data-field="kind"] dd), text: "Business Loan", exact: true)
  end

  test "the filter names a field and its values as the resource does", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/test/labelled_loans?show_custom_filter=true")

    fields = texts(view, "select[name^='field_name-'] option")
    assert "Borrower National ID" in fields
    assert "Loan Reference" in fields
    refute "Reference No" in fields

    [uuid] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("select[name^='field_name-']")
      |> LazyHTML.attribute("name")
      |> Enum.map(&String.replace_prefix(&1, "field_name-", ""))

    view
    |> element("#custom-filter-form")
    |> render_change(%{"_target" => ["field_name-#{uuid}"], "field_name-#{uuid}" => "status"})

    assert texts(view, "select[name='value-#{uuid}'] option") == [
             "",
             "Active",
             "Paid Off in Full"
           ]
  end

  test "a chip names its field and value as the resource does", %{conn: conn} do
    filter =
      %{
        "operator" => "and",
        "children" => [
          %{"field_name" => "reference_no", "operator" => "equals", "value" => "R-1"},
          %{"field_name" => "status", "operator" => "equals", "value" => "paid_off"}
        ]
      }
      |> JSON.encode!()
      |> :base64.encode()
      |> URI.encode_www_form()

    {:ok, view, _html} = live(conn, "/test/labelled_loans?custom_filter=#{filter}")

    chips =
      view
      |> texts("[data-filter-chip] > span[id$='-text']")
      |> Enum.map(&String.replace(&1, ~r/\s+/, " "))

    assert chips == ["Loan Reference = R-1", "Status = Paid Off in Full"]
  end

  test "a form labels its inputs, values and title", %{conn: conn, loan: loan} do
    {:ok, view, html} = live(conn, "/test/labelled_loans/create")

    assert html =~ "Borrower National ID"
    assert html =~ "Loan Reference"
    assert has_element?(view, "label", "Applicant")
    refute html =~ "Borrower National<"

    view |> element("#form_status_text_input") |> render_focus()

    view
    |> with_target("div[phx-feedback-for='form[status]']")
    |> render_hook("live_select_change", %{
      "text" => "",
      "id" => "form_status_live_select_component"
    })

    assert texts(view, "#form_status_live_select_component ul li") == [
             "Active",
             "Paid Off in Full"
           ]

    {:ok, _view, html} =
      live(conn, "/test/labelled_loans/#{loan.id}/issue_bill_of_sale")

    assert html =~ "Issue Bill of Sale"
    assert html =~ "Reason"
    refute html =~ "Reason Code"
  end

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
