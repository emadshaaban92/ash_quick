defmodule AshQuick.Telemetry do
  @moduledoc """
  The `:telemetry` events AshQuick emits, for a host to time, count and alert
  on what its pages do.

  Each event name starts with `:ash_quick`. A span is three events, emitted
  with `:telemetry.span/3`: `:start` before the work, then `:stop` after it or
  `:exception` if it raised, threw or exited. Their measurements are the ones
  `:telemetry.span/3` gives (`:system_time` and `:monotonic_time` on `:start`,
  `:duration` and `:monotonic_time` on `:stop` and `:exception`), and the
  metadata listed for an event is on all three. `:stop` adds what the work
  answered, `:exception` adds `:kind`, `:reason` and `:stacktrace`. A single
  event carries `:system_time` as its measurement.

  Every event runs its handlers on the process doing the work: the page's
  LiveView process, except for an export, which runs in the task the page
  starts for it. A handler that raises is detached by `:telemetry`, so keep
  handlers small and send anything slow elsewhere.

  Where an event names a `:scope`, it is the page's `socket.assigns.scope`,
  so a handler can read the actor or the tenant from it
  (`AshQuick.Scope.actor/1`, `AshQuick.Scope.tenant/1`). Where it names a
  `:quick_view`, it is the QuickView module serving the page.

  An `:exception`'s `:reason` is the error as it was raised, unredacted. An
  Ash error can quote what the visitor typed (the data layer's cast error
  repeats a filter's value) and can inspect the whole query, the actor and
  their email included, and `:scope` names the actor too. AshQuick's own log
  line for a refused filter leaves the values out, so a handler that sends
  an `:exception` off the node, to a span exporter or an error tracker,
  redacts it the same way rather than shipping `:reason` as it is.

  ## Pages

    * `[:ash_quick, :page, :load, :start | :stop | :exception]`: a QuickView
      loading what a URL asks for, on mount and on every patch: a list, a
      record's details, or the record a form opens on. Metadata: `:quick_view`,
      `:resource`, `:action` (the action's name) and `:page`, one of `:list`,
      `:details`, `:create`, `:update` and `:destroy`, and `:scope`. A list's
      load contains its `[:ash_quick, :list, :read]` span.

    * `[:ash_quick, :list, :read, :start | :stop | :exception]`: one read of a
      list's page of rows, whether the page's first, a refetch after a
      broadcast, or the read after a bulk action. Metadata: `:quick_view`,
      `:resource`, `:action`, `:scope`, `:page_number` (from 1),
      `:limit`, `:search?` and `:custom_filter?` (whether a search or a filter
      the visitor wrote narrowed it). `:stop` measures `:rows`, the rows the
      page holds. A read that raised with a custom filter is read once more
      without it, so its `:exception` is followed by a second span.

  ## Writes

    * `[:ash_quick, :form, :submit, :start | :stop | :exception]`: a form's
      save, in a modal or on its own page. Metadata: `:quick_view`,
      `:resource`, `:action`, `:type` (`:create`, `:update` or `:destroy`) and
      `:scope`. `:stop` adds `:result`, `:ok` or `:error`: an error is the
      action refusing the input, which the form then shows.

    * `[:ash_quick, :bulk, :run, :start | :stop | :exception]`: an action run
      over the rows selected on a list. Metadata: `:quick_view`, `:resource`,
      `:action`, `:type` (`:update` or `:destroy`), `:scope` and `:selected`,
      the number of rows it was asked to run over. `:stop` adds `:status`, the
      `Ash.BulkResult` status, and measures `:written`, the rows it wrote: `0`
      unless the status is `:success`, since a run that fails is rolled back
      whole.

    * `[:ash_quick, :audit, :write, :start | :stop | :exception]`: the audit
      rows an audited action or read writes to its store. Metadata:
      `:resource`, the audited resource, `:store`, `:action_type` and `:rows`,
      the number of rows written. A store refusing them raises
      `AshQuick.Audit.WriteError`, which is the `:exception`.

  ## Files

    * `[:ash_quick, :export, :start | :stop | :exception]`: a list exported
      to a file, from the count that checks `export_max_rows` to the link
      handed back. Metadata: `:quick_view`, `:resource`, `:format` (`:csv` or
      `:xlsx`), `:selection` (`:all` or `:selected`) and `:scope`. `:stop`
      adds `:result`, `:ok` or `:too_many_rows`. An export event naming any
      other format is refused before the span starts.

    * `[:ash_quick, :print, :start | :stop | :exception]`: a PDF rendered
      for what an action wrote, when the action carries `AshQuick.Print`.
      Metadata: `:resource`, `:template` and `:scope`, and `:records`, the
      number of records printed. A render that fails leaves the action's
      writes in place and flashes, and is the `:exception`.

    * `[:ash_quick, :storage, :call, :start | :stop | :exception]`: a call
      into the configured `AshQuick.Storage` module that may reach the
      storage itself: `:put_file`, `:object_arriving`, `:object_states`,
      `:object_referenced` and `:delete_expired` (what `sweep_exports/1`
      runs). Metadata: `:operation`, one of those, and `:storage`, the
      module. `:stop` adds `:result`, `:error` when the call answered
      `{:error, _}` and `:ok` otherwise. A callback the module does not
      implement is not called, and emits nothing. Signing a URL
      (`url_for/2`, `download_url/2`, `upload_target/2`) is not a call to the
      storage, and emits nothing.

  ## Refusals and gaps

    * `[:ash_quick, :route_gate, :refused]`: `AshQuick.LiveView.RouteGate`
      refusing a navigation. Metadata: `:path`, `:quick_view`, `:scope`,
      `:actor` (the real actor the scope names, if any) and `:outcome`:
      `:forbidden` when it raises `AshQuick.LiveView.RouteGate.NotAllowedError`
      (a 403), `:redirected` when it sends a tab standing in for somebody
      else to its fallback.

    * `[:ash_quick, :translation, :missing]`: a message or label AshQuick
      looked up in the host's `:gettext` backend and found no translation
      for, so it is drawn in English. Metadata: `:backend`, `:locale`,
      `:domain` (`"ash_quick"`), `:msgctxt` (`nil`, or the resource context a
      label was looked up under), `:msgid`, and `:msgid_plural` (`nil` for a
      message without plural forms). Emitted only with a backend configured:
      without one there is nothing to translate into.

      Every lookup in a locale with no `ash_quick.po` misses, the source
      language included, so a handler logging gaps skips the locale the
      msgids are written in:

          :telemetry.attach(
            "log-ash-quick-gaps",
            [:ash_quick, :translation, :missing],
            fn _event, _measurements, %{locale: locale, msgid: msgid}, _config ->
              if locale != "en", do: Logger.warning("No \#{locale} translation: \#{inspect(msgid)}")
            end,
            nil
          )

      A test can hold a page to its translations by attaching
      `:telemetry_test.attach_event_handlers/2` to the event and refuting a
      message after rendering it.

  AshQuick writes audit rows through `Ash.bulk_create/4` and reads and writes
  through Ash, so Ash's own spans (`Ash.Tracer`, and the `[:ash, ...]` events
  of `config :ash, :tracer`) still run inside these.
  """

  @doc false
  # A span named under `:ash_quick`. `fun` answers `{result, stop_metadata}`
  # or `{result, extra_measurements, stop_metadata}`, as `:telemetry.span/3`
  # takes it; the start metadata is merged under the stop metadata.
  def span(event, metadata, fun) when is_list(event) and is_map(metadata) do
    :telemetry.span([:ash_quick | event], metadata, fn ->
      case fun.() do
        {result, stop_metadata} ->
          {result, Map.merge(metadata, stop_metadata)}

        {result, measurements, stop_metadata} ->
          {result, measurements, Map.merge(metadata, stop_metadata)}
      end
    end)
  end

  @doc false
  # A single event named under `:ash_quick`, measured by when it happened.
  def event(event, metadata) when is_list(event) and is_map(metadata) do
    :telemetry.execute(
      [:ash_quick | event],
      %{system_time: System.system_time()},
      metadata
    )
  end
end
