defmodule AshQuick.FormInput.Money do
  @moduledoc """
  The form input for an `AshMoney.Types.Money` field: an amount box beside a
  currency select, which post `form[price][amount]` and
  `form[price][currency]`, the map AshMoney casts to a `Money`.

  The currencies offered are those the field's
  `constraints ex_money_opts: [only: ..., except: ...]` allows, codes or
  currency types as ex_money reads them, and always the one the field holds.
  With no `only`, they are the current ones less the metals and units no
  price is in (`XAU`, `XDR`, `XTS`, `XXX`, ...): some 165 codes, so name the
  ones a field takes. AshMoney itself casts any currency posted. With one to offer there is nothing to
  pick: the code is drawn as fixed text and posted from a hidden input. The
  select starts at the held currency, else `ex_money_opts[:default_currency]`,
  else the currency of the reader's locale.

  The amount is typed as a number is in AshQuick's other number inputs:
  left to right inside a right-to-left page, with Arabic-Indic and Persian
  digits read as 0-9 and a decimal comma as a point on the way in.

  AshQuick's own input for the type (`AshQuick.FormInput`); a host naming a
  `Money` NewType of its own can name this module for it too, and
  `AshMoney.Types.Money => false` turns it off.
  """

  @behaviour AshQuick.FormInput

  # Localize is an optional dependency of ex_money's, as ex_money is of
  # AshQuick's: every call checks it is loaded first.
  @compile {:no_warn_undefined, Localize.Currency}

  use Phoenix.Component
  use Gettext, backend: AshQuick.Gettext

  import AshQuick.Components, only: [label: 1, error: 1]

  alias AshQuick.Labels
  alias AshQuick.LiveView.Components.FieldHelp
  alias AshQuick.LiveView.FieldErrors
  alias AshQuick.LiveView.FormInputs

  @impl AshQuick.FormInput
  def render(%{field: field, phx_field: phx_field} = assigns) do
    {amount, held_currency} = split(posted(phx_field) || phx_field.value)
    opts = ex_money_opts(field)
    currencies = currencies(opts, held_currency)

    currency =
      held_currency || default_currency(opts, currencies) || List.first(currencies)

    currencies = Enum.uniq(currencies ++ List.wrap(currency))
    pick? = match?([_, _ | _], currencies)

    assigns =
      assign(assigns,
        id: phx_field.id,
        amount: amount,
        currency: currency,
        currencies: currencies,
        pick?: pick?,
        amount_name: phx_field.name <> "[amount]",
        currency_name: phx_field.name <> "[currency]",
        errors: FieldErrors.for_field(phx_field, used?(phx_field, pick?)),
        label_text: Labels.name(field.name, assigns.resource),
        number_attrs: Keyword.delete(number_attrs(field), :class),
        number_class: Keyword.get(number_attrs(field), :class)
      )

    ~H"""
    <div class="sm:col-span-2" data-money-input>
      <.label for={"#{@id}_amount"}>{@label_text}</.label>
      <span :if={not @field.allow_nil?} class="text-error"> &ast;</span>
      <div class="join w-full">
        <input
          type="text"
          id={"#{@id}_amount"}
          name={@amount_name}
          value={@amount}
          required={not @field.allow_nil?}
          autocomplete="off"
          phx-debounce="blur"
          class={[
            "input join-item min-w-0 flex-1 phx-submit-loading:pointer-events-none",
            @errors != [] && "input-error",
            @number_class
          ]}
          {amount_describe_attrs(@id, @help, @errors, @pick?)}
          {@number_attrs}
        />
        <label :if={@pick?} for={"#{@id}_currency"} class="sr-only">
          {gettext("%{field} currency", field: @label_text)}
        </label>
        <select
          :if={@pick?}
          id={"#{@id}_currency"}
          name={@currency_name}
          class={[
            "select join-item w-auto phx-submit-loading:pointer-events-none",
            @errors != [] && "select-error"
          ]}
          aria-invalid={@errors != [] && "true"}
        >
          <option :for={code <- @currencies} value={code} selected={code == @currency}>{code}</option>
        </select>
        <span
          :if={not @pick?}
          id={"#{@id}_currency"}
          class="join-item flex items-center px-3 border border-base-300 bg-base-200 text-sm"
        >
          {@currency}
        </span>
      </div>
      <input
        :if={not @pick?}
        type="hidden"
        name={@currency_name}
        value={@currency}
      />
      <FieldHelp.help id={@id} text={@help} />
      <div :if={@errors != []} id={"#{@id}-errors"}>
        <.error :for={msg <- @errors}>{msg}</.error>
      </div>
    </div>
    """
  end

  # A fixed currency is no control of its own, so the amount box names it:
  # read after the help, which says what the amount is, and before the errors.
  defp amount_describe_attrs(id, help, errors, true = _pick?),
    do: FieldHelp.describe_attrs(id, help, errors)

  defp amount_describe_attrs(id, help, errors, false = _pick?) do
    described_by =
      Enum.reject(
        [help && FieldHelp.id(id), "#{id}_currency", errors != [] && "#{id}-errors"],
        &(&1 in [nil, false])
      )

    invalid = if errors != [], do: ["aria-invalid": "true"], else: []
    invalid ++ ["aria-describedby": Enum.join(described_by, " ")]
  end

  # The map last posted, kept over the field's value: an amount cleared casts
  # to nil, which would drop the currency picked beside it.
  defp posted(%Phoenix.HTML.FormField{form: form, field: name}) do
    case Map.get(form.params || %{}, to_string(name)) do
      %{} = posted -> posted
      _not_posted -> nil
    end
  end

  # What the input shows: a held `Money`, or the map last posted, whose amount
  # is shown as typed.
  defp split(%{__struct__: Money, amount: amount, currency: currency}),
    do: {amount |> Decimal.to_string(:normal), to_string(currency)}

  defp split(%{} = posted) do
    {Map.get(posted, "amount", Map.get(posted, :amount)),
     blank_to_nil(Map.get(posted, "currency", Map.get(posted, :currency)))}
  end

  defp split(_value), do: {nil, nil}

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: to_string(value)

  # A fixed currency posts from a hidden input, which LiveView never marks
  # unused, so only the amount box and a currency select count as touching
  # the field.
  defp used?(%Phoenix.HTML.FormField{form: form, field: name}, pick?) do
    case Map.get(form.params || %{}, to_string(name)) do
      %{} = posted ->
        keys = if pick?, do: ["amount", "currency"], else: ["amount"]

        Enum.any?(
          keys,
          &(Map.has_key?(posted, &1) and not Map.has_key?(posted, "_unused_" <> &1))
        )

      _not_posted ->
        false
    end
  end

  # Typed as a decimal is (`AshQuick.LiveView.FormInputs`): left to right but
  # lined up with the page's other inputs, and a phone's number pad only when
  # `min` rules out a minus. Its `class` joins the amount box's own.
  defp number_attrs(%{constraints: constraints}) do
    min = if is_list(constraints), do: constraints[:min]
    FormInputs.attrs(%{type: Ash.Type.Decimal, constraints: [min: min]}, nil)
  end

  defp number_attrs(_field), do: [dir: "ltr", class: "rtl:text-right"]

  defp ex_money_opts(%{constraints: constraints}) when is_list(constraints),
    do: Keyword.get(constraints, :ex_money_opts, [])

  defp ex_money_opts(_field), do: []

  # ISO 4217's current codes that name no money a form would price in: the
  # precious metals, the bond-market and IMF units, the testing code and "no
  # currency". Left out when the field names no `only`.
  @not_money ~w(XAG XAU XBA XBB XBC XBD XDR XPD XPT XSU XTS XUA XXX)a

  # Codes in the order ex_money's filter names them, else sorted.
  defp currencies(opts, held) do
    {only, except} =
      case Keyword.fetch(opts, :only) do
        {:ok, only} -> {only, Keyword.get(opts, :except)}
        :error -> {:current, List.wrap(Keyword.get(opts, :except)) ++ @not_money}
      end

    codes =
      if is_list(only) and only != [] and Enum.all?(only, &code?/1),
        do: Enum.map(only, &to_string/1) -- Enum.map(List.wrap(except), &to_string/1),
        else: filtered(only, except)

    if held && held not in codes, do: codes ++ [held], else: codes
  end

  # A currency code is three capitals; anything else (`:current`, `:tender`)
  # is a type of currency.
  defp code?(code), do: to_string(code) =~ ~r/\A[A-Z]{3}\z/

  defp filtered(only, except) do
    with true <- Code.ensure_loaded?(Localize.Currency),
         {:ok, all} <- Localize.Currency.currencies_for_locale(:en),
         %{} = currencies <- Localize.Currency.currency_filter(all, only, except) do
      currencies |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    else
      _no_localize -> []
    end
  end

  defp default_currency(opts, currencies) do
    case Keyword.get(opts, :default_currency) do
      nil -> locale_currency(currencies)
      currency -> to_string(currency)
    end
  end

  defp locale_currency(currencies) do
    with true <- Code.ensure_loaded?(Localize.Currency),
         {:ok, currency} <- Localize.Currency.currency_from_locale(AshQuick.Locale.current()),
         currency = to_string(currency),
         true <- currency in currencies do
      currency
    else
      _none -> nil
    end
  end
end
