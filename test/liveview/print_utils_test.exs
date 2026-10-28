defmodule AshQuick.LiveView.PrintUtilsTest do
  @moduledoc """
  What an action's print hands the browser goes through the host's
  `:pdf_renderer`: a host with no Chrome to run in its suite names one and
  reads what each print says off the pushed event.
  """
  use ExUnit.Case, async: false

  alias AshQuick.LiveView.PrintUtils

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, validate_config_inclusion?: false

    resources do
      allow_unregistered? true
    end
  end

  defmodule Template do
    @moduledoc false
    @behaviour AshQuick.PrintTemplate

    @impl true
    def label, do: "Slip"

    @impl true
    def load_opts, do: []

    @impl true
    def render(records), do: Enum.map(records, &%{source: {:html, "<p>#{&1.name}</p>"}, opts: []})
  end

  defmodule Slip do
    @moduledoc false
    use Ash.Resource,
      domain: AshQuick.LiveView.PrintUtilsTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshQuick]

    ash_quick do
      bookkeeping do
        inserted_at false
        updated_at false
        inserted_by false
        updated_by false
      end

      liveness do
        enabled? false
      end
    end

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
    end

    actions do
      defaults [:read, create: [:name]]

      update :print do
        accept []

        change {AshQuick.Print,
                template: AshQuick.LiveView.PrintUtilsTest.Template, delivery: :print}
      end
    end
  end

  defmodule SecretSlip do
    @moduledoc false
    # Labelled by a `sensitive?` field, which no filename may carry.
    use Ash.Resource,
      domain: AshQuick.LiveView.PrintUtilsTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshQuick]

    ash_quick do
      display do
        label :pin
      end

      bookkeeping do
        inserted_at false
        updated_at false
        inserted_by false
        updated_by false
      end

      liveness do
        enabled? false
      end
    end

    ets do
      private? true
    end

    attributes do
      uuid_primary_key :id
      attribute :name, :string, public?: true
      attribute :pin, :string, public?: true, sensitive?: true
    end

    actions do
      defaults [:read, create: [:name, :pin]]

      update :print do
        accept []

        change {AshQuick.Print,
                template: AshQuick.LiveView.PrintUtilsTest.Template, delivery: :print}
      end
    end
  end

  defmodule Renderer do
    @moduledoc false
    @behaviour AshQuick.PdfRenderer

    @impl true
    def render(sources) when is_list(sources) do
      sources |> Enum.map_join(&elem(&1.source, 1)) |> Base.encode64()
    end
  end

  defmodule FailingRenderer do
    @moduledoc false
    @behaviour AshQuick.PdfRenderer

    @impl true
    def render(_sources), do: raise("no Chrome here")
  end

  setup do
    previous = Application.fetch_env(:ash_quick, :pdf_renderer)

    on_exit(fn ->
      case previous do
        {:ok, renderer} -> Application.put_env(:ash_quick, :pdf_renderer, renderer)
        :error -> Application.delete_env(:ash_quick, :pdf_renderer)
      end
    end)
  end

  defp socket do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, scope: nil, flash: %{}},
      private: %{live_temp: %{}}
    }
  end

  defp printed(names) do
    records =
      for name <- names do
        Slip
        |> Ash.Changeset.for_create(:create, %{name: name})
        |> Ash.create!(authorize?: false)
      end

    Ash.bulk_update(records, :print, %{},
      authorize?: false,
      strategy: :stream,
      return_records?: true
    )
    |> Map.update!(:records, fn written ->
      Enum.sort_by(written, &Enum.find_index(names, fn name -> name == &1.name end))
    end)
  end

  test "pushes what the configured renderer made of the template's output" do
    Application.put_env(:ash_quick, :pdf_renderer, Renderer)

    socket = PrintUtils.print(socket(), printed(["first", "second"]))

    assert [["ash_quick:pdf", %{data: data, delivery: :print}]] =
             socket.private.live_temp.push_events

    assert Base.decode64!(data) == "<p>first</p><p>second</p>"
  end

  test "names the file for the record, or says redacted for a sensitive label" do
    Application.put_env(:ash_quick, :pdf_renderer, Renderer)

    socket = PrintUtils.print(socket(), printed(["first"]))

    assert [["ash_quick:pdf", %{filename: "first_slip-" <> _}]] =
             socket.private.live_temp.push_events

    secret =
      SecretSlip
      |> Ash.Changeset.for_create(:create, %{name: "vault", pin: "4321"})
      |> Ash.create!(authorize?: false)

    socket =
      PrintUtils.print(
        socket(),
        Ash.bulk_update([secret], :print, %{},
          authorize?: false,
          strategy: :stream,
          return_records?: true
        )
      )

    assert [["ash_quick:pdf", %{filename: "redacted_slip-" <> _ = filename}]] =
             socket.private.live_temp.push_events

    refute filename =~ "4321"
  end

  test "a renderer that fails leaves the print undelivered and says so" do
    Application.put_env(:ash_quick, :pdf_renderer, FailingRenderer)

    socket =
      ExUnit.CaptureLog.with_log(fn -> PrintUtils.print(socket(), printed(["only"])) end)
      |> elem(0)

    refute Map.has_key?(socket.private.live_temp, :push_events)
    assert socket.assigns.flash["error"] =~ "its PDF could not be produced"
  end

  test "ChromicPDF is the renderer unless the host names another" do
    Application.delete_env(:ash_quick, :pdf_renderer)

    assert AshQuick.Config.pdf_renderer() == AshQuick.PdfRenderer.ChromicPDF
  end
end
