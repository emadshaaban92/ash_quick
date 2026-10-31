defmodule AshQuick.LabelsTest do
  @moduledoc """
  A label is looked up in the host's `:gettext` backend, in the `ash_quick`
  domain and that backend's locale, and anything that is not a string is drawn
  as it is.

  Not async: the backend is application config, read on every call.
  """
  use ExUnit.Case, async: false

  import Phoenix.Component, only: [sigil_H: 2]

  alias AshQuick.Labels

  setup do
    original = Application.get_env(:ash_quick, :gettext)
    Application.put_env(:ash_quick, :gettext, AshQuick.Test.LabelGettext)
    on_exit(fn -> Application.put_env(:ash_quick, :gettext, original) end)

    Gettext.put_locale(AshQuick.Test.LabelGettext, "ar")
    :ok
  end

  test "a string is translated, and a name is humanized first" do
    assert Labels.translate("Price") == "السعر"
    assert Labels.name(:shelf_life) == "مدة الصلاحية"
    assert Labels.translate("Unlisted") == "Unlisted"
  end

  # No name is special but `destroy`: a host rewords one with a `label:` or a
  # translation, and the English the catalogue keys on is what it reads here.
  test "a name reads as its words, title-cased" do
    assert Labels.name(:vat_number) == "Vat Number"
    assert Labels.name(:name_ar) == "Name Ar"
    assert Labels.name(:destroy) == "Delete"
  end

  # A `label:` option is stored unchecked, so markup that rendered before
  # labels were translated still renders rather than taking the LiveView down.
  test "anything but a string is drawn as it is" do
    assigns = %{}
    markup = ~H"<b>Price</b>"

    assert Labels.translate(markup) == markup
    assert Labels.translate(nil) == nil
    assert Labels.translate(:price) == :price
  end

  test "a field is labelled by its label option, or its name" do
    assert Labels.field(:price) == "السعر"
    assert Labels.field({:cost, "Price"}) == "السعر"
    assert Labels.field({:shelf_life, widget: nil}) == "مدة الصلاحية"
    assert Labels.field([:price]) == "السعر"
  end

  describe "a label the resource declares" do
    alias AshQuick.LiveView.EnumOptions
    alias AshQuick.LiveView.QuickField
    alias AshQuick.Test.Labels.Loan

    test "names its field, relationship, action and argument, translated" do
      assert Labels.name(:borrower_national_id, Loan) == "الرقم القومي للمقترض"
      assert Labels.name(:borrower, Loan) == "Applicant"
      assert Labels.name(:issue_bill_of_sale, Loan) == "Issue Bill of Sale"
      assert Labels.name(:reason_code, Loan) == "Reason"
    end

    test "leaves what it does not label, and every other resource, humanized" do
      assert Labels.name(:kind, Loan) == "Kind"
      assert Labels.name(:destroy, Loan) == "Delete"
      assert Labels.name(:borrower_national_id) == "Borrower National"

      assert Labels.name(:borrower_national_id, AshQuick.Test.Labels.Borrower) ==
               "Borrower National"
    end

    test "is the English it is translated from" do
      Gettext.put_locale(AshQuick.Test.LabelGettext, "en")

      assert Labels.name(:borrower_national_id, Loan) == "Borrower National ID"
    end

    test "labels a field entry, under its own label: option" do
      assert Labels.field(:borrower_national_id, Loan) == "الرقم القومي للمقترض"
      assert Labels.field({:borrower_national_id, widget: nil}, Loan) == "الرقم القومي للمقترض"
      assert Labels.field({:borrower_national_id, "ID"}, Loan) == "ID"
      assert Labels.field({:borrower_national_id, label: "ID"}, Loan) == "ID"
    end

    # A path is labelled by the field it reaches, as the related resource
    # labels it; one stopping at the related record, by the relationship.
    test "labels a relationship path by what it reaches" do
      assert Labels.field([borrower: :national_id], Loan) == "National ID"
      assert Labels.field([borrower: :name], Loan) == "Name"
      assert Labels.field([borrower: []], Loan) == "Applicant"
    end

    test "is the label a QuickView's field is normalized with" do
      assert QuickField.normalize(:borrower_national_id, Loan).label == "Borrower National ID"
      assert QuickField.normalize([borrower: :national_id], Loan).label == "National ID"
      assert QuickField.normalize(:borrower_national_id).label == "Borrower National"
    end

    test "labels a value, in place of its enum's label or its humanized name" do
      status = Ash.Resource.Info.attribute(Loan, :status)
      kind = Ash.Resource.Info.attribute(Loan, :kind)

      assert EnumOptions.options(status, Loan) == [
               {"Active", :active},
               {"مسدد بالكامل", :paid_off},
               {"ملغى", :cancelled}
             ]

      assert EnumOptions.label(status, :paid_off) == "Paid off"
      assert EnumOptions.label(kind, :business, Loan) == "Business Loan"
      assert EnumOptions.label(kind, :personal, Loan) == "Personal"
    end

    # What a custom template holds is the value, not the field struct.
    test "labels a value by its field's name" do
      assert Labels.value(Loan, :status, :paid_off) == "مسدد بالكامل"
      assert Labels.value(Loan, :status, :active) == "Active"
      assert Labels.value(Loan, :kind, :business) == "Business Loan"
      assert Labels.value(Loan, :kind, :personal) == "Personal"
      assert Labels.value(Loan, :no_such_field, :paid_off) == "Paid Off"
      assert Labels.value(Loan, :status, nil) == nil

      # A name, not a value: `name/2` reads the field's or action's label.
      assert Labels.name(:paid_off, Loan) == "Paid Off"
    end
  end

  # A word agrees with the noun it describes: the catalogue translates
  # "Cancelled" for a loan's status apart from everywhere else.
  describe "a label's context" do
    alias AshQuick.LiveView.EnumOptions
    alias AshQuick.Test.Labels.{Borrower, Loan}

    test "is the resource's short name, and its field's for a value" do
      assert Labels.context(Loan) == "loan"
      assert Labels.context(Loan, :status) == "loan.status"
      assert Labels.context(nil) == nil
    end

    test "picks the translation the catalogue gives under it" do
      status = Ash.Resource.Info.attribute(Loan, :status)

      assert Labels.translate("Cancelled", "loan.status") == "ملغى"
      assert EnumOptions.label(status, :cancelled, Loan) == "ملغى"
      assert {"ملغى", :cancelled} in EnumOptions.options(status, Loan)
      assert Labels.value(Loan, :status, :cancelled) == "ملغى"
      assert Labels.name(:name, Loan) == "اسم القرض"
      assert Labels.field(:name, Loan) == "اسم القرض"
    end

    test "falls back to the context-free translation" do
      status = Ash.Resource.Info.attribute(Loan, :status)

      assert Labels.translate("Cancelled", "approval.status") == "ملغاة"
      assert Labels.translate("Cancelled") == "ملغاة"
      assert EnumOptions.label(status, :cancelled) == "ملغاة"
      assert Labels.name(:name, Borrower) == "Name"
      assert Labels.field([borrower: :name], Loan) == "Name"
    end

    # An entry with an empty msgstr is untranslated: Gettext compiles it as
    # missing, and the context-free translation stands.
    test "is passed over where its entry is left empty" do
      assert Labels.name(:borrower_national_id, Loan) == "الرقم القومي للمقترض"
    end

    test "costs the missing-translation hook nothing when either variant is translated" do
      Labels.translate("Cancelled", "approval.status")
      Labels.translate("Price", "loan")
      Labels.name(:name, Loan)

      refute_received {:missing_translation, _, _, _, _}
    end

    test "is named to the missing-translation hook when neither variant is translated" do
      assert Labels.name(:reason_code, Loan) == "Reason"

      assert_received {:missing_translation, "ar", "ash_quick", "loan", "Reason"}
      refute_received {:missing_translation, _, _, nil, "Reason"}
    end
  end

  test "in the host's default locale, a label is drawn as it is" do
    Gettext.put_locale(AshQuick.Test.LabelGettext, "en")

    assert Labels.translate("Price") == "Price"
  end

  # A label is text, not a message with bindings.
  test "a label holding a binding's syntax is drawn as written" do
    assert Labels.translate("Rate (%{unit})") == "Rate (%{unit})"

    Application.delete_env(:ash_quick, :gettext)
    assert Labels.translate("Rate (%{unit})") == "Rate (%{unit})"
  end

  test "with no backend, a label is drawn as it is" do
    Application.delete_env(:ash_quick, :gettext)

    assert Labels.translate("Price") == "Price"
    assert Labels.name(:shelf_life) == "Shelf Life"
  end
end
