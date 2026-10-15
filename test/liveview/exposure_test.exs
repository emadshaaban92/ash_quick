defmodule AshQuick.LiveView.ExposureTest do
  @moduledoc """
  What a QuickView lets a visitor reach, judged by what Ash says may be exposed.

  Two Ash features decide it, and a page predating them got both wrong.

  An action declared `public?: false` is internal: Ash's documentation says no
  extension may expose one, and recommends a `private_action?()` bypass that
  lets every call to one through. A page that offers such an action, or runs one
  a browser names, hands it to a visitor with no policy in the way. Every place
  a page lists or resolves an action is pinned here to public ones.

  A field a field policy hides is read back as `%Ash.ForbiddenField{}`, which
  HEEx cannot render, so a single policy on a listed column used to crash the
  page for whoever it hid the column from. A hidden field renders as a mark,
  a widget is never handed one, and a column hidden on every record is left out.
  """
  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest, only: [render_component: 2, rendered_to_string: 1]

  alias AshQuick.LiveView.Components.{DetailsView, FieldValue, ListView}
  alias AshQuick.LiveView.ListUtils
  alias AshQuick.LiveView.QuickField
  alias AshQuick.LiveView.QuickView
  alias AshQuick.LiveView.QuickView.Options
  alias AshQuick.LiveView.URLParams
  alias AshQuick.LiveView.Utils
  alias AshQuick.Test.Exposure.Payslip

  @actor %{id: "8d3c5f0e-2a7b-4c1d-9e6f-0b1a2c3d4e5f"}

  def widget(assigns) do
    ~H"""
    <span class="widget-value">{inspect(@value)}</span>
    """
  end

  @fields [:name, :amount, {:owner_id, widget: &__MODULE__.widget/1}]

  defp options(opts \\ []) do
    Options.new(
      __MODULE__.SomeQuickView,
      Payslip,
      Keyword.merge(
        [resource: Payslip, list: [fields: @fields], details: [fields: @fields]],
        opts
      )
    )
  end

  defp names(actions), do: Enum.map(actions, & &1.name)

  describe "private actions" do
    test "pass the policy Ash recommends for them, so the menu cannot rely on it" do
      # Why the rest of this block exists. `AshQuick.can?` is what a menu is
      # filtered through, and for an internal action it says yes.
      assert AshQuick.can?({Payslip, :recompute}, @actor, :ash_quick_list_bulk)
      assert AshQuick.can?({%Payslip{id: "p"}, :purge}, @actor, :ash_quick_list)
    end

    test "are not among the actions a page may take on a record" do
      assert names(Utils.record_actions(Payslip)) == [:update, :destroy]
    end

    test "are not derived into the bulk menu" do
      titles =
        Payslip
        |> ListUtils.resource_bulk_actions(@actor, options())
        |> Enum.map(& &1.title)

      # `:update` takes input, so it was never derivable; `:destroy` is the one
      # public action that is, and it is there.
      assert titles == ["Delete"]
    end

    test "are refused when an event names one" do
      actions = Utils.record_actions(Payslip)

      assert Utils.offered_action(actions, "update").name == :update
      assert Utils.offered_action(actions, "destroy").name == :destroy
      assert Utils.offered_action(actions, "recompute") == nil
      assert Utils.offered_action(actions, "purge") == nil
      # Real actions of other types, which a lookup on the resource would find.
      assert Utils.offered_action(actions, "read") == nil
      assert Utils.offered_action(actions, "import") == nil
      # A name that is no atom at all is refused rather than raising.
      assert Utils.offered_action(actions, "not_an_action_#{System.unique_integer()}") == nil
      assert Utils.offered_action(actions, nil) == nil
    end

    test "are not reachable from the URL" do
      options = options()

      resolved = fn url_params, live_action ->
        {_params, action} = QuickView.resolve(url_params, options, live_action)
        action && action.name
      end

      assert resolved.(%{"id" => "p", "action" => "update"}, nil) == :update
      assert resolved.(%{"id" => "p", "action" => "recompute"}, nil) == nil
      assert resolved.(%{"id" => "p", "action" => "payroll_export"}, nil) == nil
      assert resolved.(%{"action" => "import"}, :create) == nil
      assert resolved.(%{}, :create) == :create
    end

    test "are reachable as a default the page itself names" do
      # The host wrote this one in code, so it is not a visitor's choice. A
      # lookup kept private so no API serves it is the common case.
      options = options(details: [fields: @fields, default_action: :payroll_export])

      assert {_params, %{name: :payroll_export}} =
               QuickView.resolve(%{"id" => "p"}, options, nil)
    end

    test "are not offered on the details page" do
      options = options()

      html =
        %{
          __changed__: nil,
          record: %Payslip{id: "p", name: "October", owner_id: @actor.id},
          resource: Payslip,
          scope: @actor,
          options: options,
          fields: options.details_fields,
          base_path: "/payslips",
          params: %URLParams{}
        }
        |> DetailsView.details_view()
        |> rendered_to_string()

      # The page's own actions are there, so the refutals are not passing for
      # want of any controls.
      assert html =~ "action_name&quot;:&quot;update"
      assert html =~ "action_name&quot;:&quot;destroy"
      refute html =~ "recompute"
      refute html =~ "purge"
    end
  end

  describe "fields a field policy hides" do
    defp read_as(actor, attrs) do
      Payslip
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.create!(authorize?: false)

      Payslip |> Ash.read!(actor: actor) |> Enum.find(&(&1.name == attrs.name))
    end

    test "render as a mark rather than crashing the page" do
      payslip = read_as(@actor, %{name: "Hidden amount", amount: 1200})
      assert %Ash.ForbiddenField{} = payslip.amount

      html =
        render_component(&FieldValue.field_value/1, value: payslip, path: :amount, scope: @actor)

      assert html =~ "Hidden"
      refute html =~ "1200"
    end

    test "render normally on the records the policy shows them on" do
      own = read_as(@actor, %{name: "Own", owner_id: @actor.id})
      other = read_as(@actor, %{name: "Other", owner_id: Ash.UUID.generate()})

      assert render_component(&FieldValue.field_value/1, value: own, path: :owner_id) =~
               @actor.id

      assert render_component(&FieldValue.field_value/1, value: other, path: :owner_id) =~
               "Hidden"
    end

    test "are passed on past a relationship, not read through" do
      forbidden = %Ash.ForbiddenField{field: :owner, type: :relationship}

      assert QuickField.resolve_value(%{owner: forbidden}, [{:owner, :name}]) == forbidden
    end

    test "leave out a column hidden on every record, and keep one that depends on the record" do
      action = Ash.Resource.Info.action(Payslip, :index)

      fields =
        options().list_fields
        |> Utils.visible_fields(Payslip, action, @actor)
        |> Enum.map(&Utils.field_path/1)

      assert fields == [:name, :owner_id]
    end

    test "are left out of the list, and no widget is handed one" do
      options = options()
      action = Ash.Resource.Info.action(Payslip, options.list_default_action)

      record = %Payslip{
        id: "p",
        name: "Someone else's",
        amount: %Ash.ForbiddenField{field: :amount, type: :attribute},
        owner_id: %Ash.ForbiddenField{field: :owner_id, type: :attribute}
      }

      assigns = %{
        __changed__: %{},
        resource: Payslip,
        scope: @actor,
        path: "/payslips",
        base_path: "/payslips",
        params: %URLParams{},
        routed_shapes: [],
        filters: nil,
        selected_rows: %{},
        action_running: false,
        row_actions: nil,
        export_data: nil,
        data: %{results: [record], count: 1, limit: 20, offset: 0}
      }

      socket =
        QuickView.prepare_assigns(%Phoenix.LiveView.Socket{assigns: assigns}, action, options)

      assert Enum.map(socket.assigns.fields, & &1.label) == ["Name", "Owner"]

      html = socket.assigns |> ListView.list_view() |> rendered_to_string()

      assert html =~ "Someone else&#39;s"
      assert html =~ "Hidden"
      refute html =~ "widget-value"
      refute html =~ "Amount"
    end
  end
end
