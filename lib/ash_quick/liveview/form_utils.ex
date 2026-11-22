defmodule AshQuick.LiveView.FormUtils do
  @moduledoc false
  # An action form's life on the page: building it from the URL, the events it
  # handles while open, the save and where the page goes after it. What it
  # hands off lives beside it: `FormParams` shapes the params, `FormSaveErrors`
  # words a refused save, `FormUploads` and `FormAttachments` carry its files,
  # `AttachmentKeys` checks the keys a post names, and `AttachmentUpload`
  # signs and names each upload.
  require Ash.Query
  require Logger
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2]
  use Gettext, backend: AshQuick.Gettext
  alias AshQuick.Labels
  alias AshQuick.LiveView.ActionErrors
  alias AshQuick.LiveView.AttachmentKeys
  alias AshQuick.LiveView.AttachmentUpload
  alias AshQuick.LiveView.FieldErrors
  alias AshQuick.LiveView.FormAttachments
  alias AshQuick.LiveView.FormParams
  alias AshQuick.LiveView.FormSaveErrors
  alias AshQuick.LiveView.FormStateFlow
  alias AshQuick.LiveView.FormUploads
  alias AshQuick.LiveView.DownloadUtils
  alias AshQuick.LiveView.PrintUtils
  alias AshQuick.LiveView.URLParams
  alias AshQuick.LiveView.QuickView.Options
  alias AshQuick.LiveView.Components.FormView
  alias AshQuick.LiveView.DetailsUtils
  alias AshQuick.LiveView.ListUtils
  alias AshQuick.LiveView.Utils

  # Hosts call these here; `AshQuick.LiveView.AttachmentUpload` documents them.
  @doc false
  defdelegate presign_attachment_upload(entry, socket, constraints), to: AttachmentUpload
  @doc false
  defdelegate upload_error_message(error), to: AttachmentUpload
  @doc false
  defdelegate safe_filename(name), to: AttachmentUpload

  def do_handle_params(
        socket,
        %URLParams{} = params,
        %{type: action_type, name: action_name} = _action,
        %Options{} = options
      )
      when action_type in [:create, :update, :destroy] do
    socket
    |> detach_hook(:quick_view_events_hook, :handle_event)
    |> attach_hook(:quick_view_events_hook, :handle_event, fn
      event, params, socket -> handle_form_events(event, params, socket, options)
    end)
    |> detach_hook(:quick_view_async_hooks, :handle_async)
    |> attach_hook(:quick_view_async_hooks, :handle_async, fn
      _name, _result, socket -> {:cont, socket}
    end)
    |> set_title(action_name, options)
    |> set_record!(action_type, action_name, params, options)
    |> set_form(action_type, options)
    |> FormStateFlow.store(:build)
    |> then(&FormUploads.allow_image_upload(&1, &1.assigns.form))
    |> then(&assign(&1, ash_quick_refusal: FormView.refusal(&1.assigns)))
  end

  defp set_title(socket, action_name, %{resource: resource}) do
    resource_name = Ash.Resource.Info.short_name(resource)

    title =
      gettext("[%{resource}] %{action}",
        resource: Labels.name(resource_name),
        action: Labels.name(action_name, resource)
      )

    socket |> assign(page_title: title)
  end

  defp set_record!(socket, :create, _action_name, _params, _options), do: socket

  defp set_record!(socket, action_type, action_name, %URLParams{id: id}, options)
       when action_type in [:update, :destroy] do
    # A relationship is named whole rather than by a field of it: a dropdown
    # seeds its currently-selected option from this record rather than from its
    # own query, and `load_fields/3` brings the destination's display label
    # along with the relationship — otherwise the one option the user is
    # actually looking at is the one rendered as a UUID.
    action_fields =
      Utils.action_fields(options.resource, action_name)
      |> Enum.map(&Utils.argument_to_relationship(&1, options.resource, action_name))

    fields =
      action_fields
      |> Enum.map(fn
        %Ash.Resource.Attribute{name: name} -> name
        %Ash.Resource.Relationships.BelongsTo{name: name} -> name
        %Ash.Resource.Relationships.ManyToMany{name: name} -> name
        _ -> []
      end)
      # What the record is called, which a confirmation names it by.
      |> then(&[AshQuick.Info.display_label(options.resource) | &1])

    record =
      options.resource
      |> Ash.Query.for_read(:read, %{}, scope: socket.assigns.scope)
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.load(options.load, strict?: true)
      |> Utils.load_fields(fields, strict?: true)
      |> then(&Ash.Query.load(&1, picked_hint_load(action_type, action_fields, &1.tenant)))
      |> Ash.read_one!()

    socket |> assign(record: record)
  end

  # An update form's dropdowns draw their picked records with the
  # destination's hint, and the strict relationship load above brings the
  # label alone. Merged rather than strict, so it adds the hint without
  # narrowing that load. A destroy confirmation draws no dropdown.
  defp picked_hint_load(:update, action_fields, tenant) do
    for %struct{name: name, destination: destination} <- action_fields,
        struct in [
          Ash.Resource.Relationships.BelongsTo,
          Ash.Resource.Relationships.ManyToMany
        ],
        fields = Utils.hint_fields(destination, tenant),
        fields != [],
        do: {name, fields}
  end

  defp picked_hint_load(_action_type, _action_fields, _tenant), do: []

  defp set_form(socket, :create, _options) do
    form =
      AshPhoenix.Form.for_create(socket.assigns.resource, socket.assigns.ash_action.name,
        forms:
          FormParams.with_nested_digits(
            Utils.nested_forms(socket.assigns.resource, socket.assigns.ash_action.name, [])
          ),
        transform_params: &FormParams.transform_nested_params/3,
        transform_errors: &ActionErrors.renderable_vars/2,
        scope: socket.assigns.scope,
        actor: actor(socket),
        context: stage_context(AshQuick.form_build_stage())
      )
      |> then(&add_nested_forms(&1, &1.form_keys))
      |> opened()

    socket |> assign(form: form) |> AttachmentKeys.assign_issued_attachment_keys()
  end

  # The read in `set_record!/5` runs through the actor's scope, so a record the
  # actor may not read comes back as nil — indistinguishable from one that does
  # not exist. There is no form to build for it: leave `form: nil` and let
  # `FormView.form_view/1` render the forbidden panel.
  defp set_form(%{assigns: %{record: nil}} = socket, action_type, _options)
       when action_type in [:update, :destroy] do
    socket |> assign(form: nil)
  end

  defp set_form(socket, :destroy, _options) do
    form =
      AshPhoenix.Form.for_destroy(socket.assigns.record, socket.assigns.ash_action.name,
        transform_params: &FormParams.transform_nested_params/3,
        transform_errors: &ActionErrors.renderable_vars/2,
        scope: socket.assigns.scope,
        actor: actor(socket),
        context: stage_context(AshQuick.form_build_stage())
      )
      |> opened()

    socket |> assign(form: form) |> AttachmentKeys.assign_issued_attachment_keys()
  end

  # A field a field policy hides on the record gets no sub-form: Ash read it
  # as `%Ash.ForbiddenField{}`, which there is nothing to build one over. See
  # `Utils.form_fields/1`, which keeps every other path off it.
  defp set_form(socket, :update, _options) do
    %{record: record, resource: resource, ash_action: %{name: action}} = socket.assigns

    form =
      AshPhoenix.Form.for_update(record, action,
        forms:
          resource
          |> Utils.nested_forms(action, Utils.hidden_field_names(record))
          |> FormParams.with_nested_digits(),
        transform_params: &FormParams.transform_nested_params/3,
        transform_errors: &ActionErrors.renderable_vars/2,
        scope: socket.assigns.scope,
        actor: actor(socket),
        context: stage_context(AshQuick.form_build_stage())
      )
      |> then(&add_nested_forms(&1, &1.form_keys))
      |> FormParams.prefill_form_has_many_args(socket)
      |> FormParams.prefill_changed_embedded_forms()
      |> opened()

    socket |> assign(form: form) |> AttachmentKeys.assign_issued_attachment_keys()
  end

  # The form is open. Building it ran the action's changes once, under the
  # build stage, prefills included, and nothing they set survives a rebuild:
  # `AshPhoenix.Form.validate/3` builds a new changeset from `form.data`, the
  # params and the form's options every time. So whatever the build set on the
  # action's inputs becomes the form's initial params, and every validate from
  # here on, a `phx-change` or this module's own (an upload's, which rebuilds
  # from `raw_params`), runs under the validate stage and agrees with what the
  # page shows. Nested forms carry their own params, and are left to them.
  defp opened(form) do
    built = built_input_params(form)
    form = put_stage(form, AshQuick.form_validate_stage())

    if map_size(built) == 0 do
      form
    else
      AshPhoenix.Form.validate(form, Map.merge(form.raw_params || %{}, built), errors: false)
    end
  end

  # Each input the action takes that the built changeset holds a value for and
  # the params do not: an argument set to a value, or an accepted attribute the
  # build changed. An input left at its static default, or an attribute at the
  # record's own value, is what the form shows without any build, and stays
  # out: such a value in the params would read as one the person posted. It is
  # the value that decides, not `changeset.defaults`: a change that sets an
  # attribute to its default (`[]` for an attachment list) is just as unposted,
  # and in the params would read as a list emptied by its ✕.
  defp built_input_params(form) do
    held = form.raw_params || %{}
    nested = form.form_keys |> Keyword.keys() |> MapSet.new(&to_string/1)

    form.resource
    |> Ash.Resource.Info.action_inputs(form.action)
    |> MapSet.new(&to_string/1)
    |> Enum.reject(&(MapSet.member?(nested, &1) or Map.has_key?(held, &1)))
    |> Enum.flat_map(fn key ->
      case built_value(form.source, key) do
        {:ok, value} -> [{key, value}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp built_value(changeset, key) do
    argument = Enum.find(changeset.action.arguments, &(to_string(&1.name) == key))
    attribute = Ash.Resource.Info.attribute(changeset.resource, key)

    cond do
      argument ->
        changeset
        |> Ash.Changeset.fetch_argument(argument.name)
        |> unless_unbuilt([nil, static_default(argument)])

      attribute && Ash.Changeset.changing_attribute?(changeset, attribute.name) ->
        {:ok, Ash.Changeset.get_attribute(changeset, attribute.name)}
        |> unless_unbuilt([unbuilt_value(changeset, attribute)])

      true ->
        :error
    end
  end

  defp unless_unbuilt({:ok, value}, unbuilt),
    do: if(value in unbuilt, do: :error, else: {:ok, value})

  defp unless_unbuilt(:error, _unbuilt), do: :error

  defp unbuilt_value(%{action_type: :create}, attribute), do: static_default(attribute)
  defp unbuilt_value(changeset, attribute), do: Map.get(changeset.data, attribute.name)

  defp static_default(%{default: default})
       when not is_function(default) and not is_tuple(default),
       do: default

  defp static_default(_input), do: :no_static_default

  # AshPhoenix doesn't derive an actor from the scope for nested-form
  # sub-changesets, so pass it explicitly for managed relationships.
  defp actor(socket) do
    case Ash.Scope.ToOpts.get_actor(socket.assigns.scope) do
      {:ok, actor} -> actor
      _ -> nil
    end
  end

  defp add_nested_forms(form, form_keys) do
    form_keys
    |> Enum.reject(&(Map.has_key?(form.forms, elem(&1, 0)) or elem(&1, 1)[:type] == :list))
    |> Enum.reduce(form, fn {field_name, _}, form_acc ->
      form_acc |> AshPhoenix.Form.add_form(form.name <> "[#{field_name}]")
    end)
  end

  @events ~w(cancel-upload add-form remove-form remove-attachment validate save)

  @doc false
  def events, do: @events

  # The page shows the forbidden panel in place of the form: the actor may not
  # run the action, may change none of what it takes, or may not read the
  # record, in which case no form was built. Nothing stops someone pushing a
  # form event at it anyway. Refuse it as the panel words it, rather than build
  # on a nil form or run what the panel says is refused.
  defp handle_form_events(event, params, socket, options) when event in @events do
    case FormView.held_refusal(socket.assigns) do
      :ok ->
        handle_open_form_events(event, params, socket, options)

      {:forbidden, message} ->
        {:halt, put_flash(socket, :error, message || ActionErrors.forbidden_message())}
    end
  end

  # The page the modal opened over is still drawn under it, inert, from a
  # snapshot. A click cannot reach it, but its events still arrive: on a
  # reconnect LiveView's form recovery replays every `phx-change` form with an
  # id, inert or not (the list's search, selection and page-size forms), and
  # anything can be sent by hand. The form's hook has replaced that page's, so
  # passed on, such an event would reach the QuickView module, which has no
  # clause for it, and crash the view. It is dropped. Any other name is the
  # host's and goes on.
  defp handle_form_events(event, _params, socket, _options) do
    if event in ListUtils.events() or event in DetailsUtils.events(),
      do: {:halt, socket},
      else: {:cont, socket}
  end

  defp handle_open_form_events("cancel-upload", params, socket, _options) do
    {:halt, socket |> cancel_upload(params["entry"], params["ref"]) |> clear_flash()}
  end

  defp handle_open_form_events("add-form", %{"path" => path}, socket, _options) do
    form = AshPhoenix.Form.add_form(socket.assigns.form, path)

    {:halt,
     socket
     |> assign(form: form)
     |> FormStateFlow.store(:validate)
     |> FormUploads.allow_image_upload(form)
     |> FormAttachments.clear_form_flash()}
  end

  defp handle_open_form_events("remove-form", %{"path" => path}, socket, _options) do
    held = socket.assigns.form
    form = AshPhoenix.Form.remove_form(held, path)

    {:halt,
     socket
     |> FormUploads.follow_removed_sub_form(held, form, path)
     |> assign(form: form)
     |> FormStateFlow.store(:validate)
     |> FormAttachments.clear_form_flash()}
  end

  # The ✕ beside a stored file. The page says which field and, in a list, which
  # position, and nothing else: there is no value of the client's to take.
  #
  # Without a position it is the ✕ beside a single attachment the field may
  # leave empty: the field is emptied, and its hidden input then posts it blank.
  # With one, it names a position in an array attribute of attachments, whose
  # list is held here. Anything else (a required attachment, a position that is
  # not there, a field of another kind) is ignored rather than passed on to the
  # host's own `handle_event/3`.
  defp handle_open_form_events("remove-attachment", %{"field" => name} = params, socket, _options)
       when is_binary(name) and not is_map_key(params, "index") do
    case FormAttachments.clearable_attachment_field(socket.assigns.form, name) do
      %{} = field ->
        cleared = Map.get(socket.assigns, :ash_quick_cleared_attachments, MapSet.new())

        {:halt,
         socket
         |> assign(ash_quick_cleared_attachments: MapSet.put(cleared, field.name))
         |> FormAttachments.put_field_value(field, nil)
         |> clear_flash()}

      nil ->
        {:halt, socket}
    end
  end

  defp handle_open_form_events("remove-attachment", params, socket, _options) do
    form = socket.assigns.form

    with %{"field" => name, "index" => index} when is_binary(name) <- params,
         %{} = field <- FormAttachments.held_attachments_field(form, name),
         {:ok, position} <- attachment_position(index),
         held when is_list(held) and position < length(held) <-
           FormAttachments.held_attachments(form, field) do
      {:halt,
       socket
       |> FormAttachments.put_field_value(field, List.delete_at(held, position))
       |> clear_flash()}
    else
      _nothing_to_remove -> {:halt, socket}
    end
  end

  # A form whose only inputs are uploads (an action taking nothing but an
  # `add_*` argument) posts no `form` params at all: a file input's value never
  # travels with the form. Nor does a confirmation, which has no inputs. Both
  # are an empty form, not someone else's event.
  defp handle_open_form_events(event, params, socket, options)
       when event in ["validate", "save"] and not is_map_key(params, "form") do
    handle_open_form_events(event, Map.put(params, "form", %{}), socket, options)
  end

  defp handle_open_form_events("validate", %{"form" => params} = event, socket, _options) do
    params =
      params
      |> FieldErrors.mark_used(event["_target"])
      |> FormParams.put_emptied_selections()
      |> FormAttachments.carry_uploaded_attachments(socket.assigns.form)
      |> FormParams.maybe_put_has_many(socket.assigns.form)

    held = socket.assigns.form

    # What the state hides is dropped from the params just posted, never from
    # the page drawn last: a hand-made post can name a hidden field.
    case AttachmentKeys.validate_issued(held, params, socket) do
      {params, form} ->
        {_params, form, state} = FormStateFlow.settle(held, params, form, :validate, socket)

        {:halt,
         socket
         |> assign(form: form)
         |> assign(ash_quick_form_state: state)
         |> FormAttachments.clear_form_flash()}

      :refused ->
        {:halt, socket}
    end
  end

  defp handle_open_form_events("save", %{"form" => params}, socket, _options) do
    params =
      params
      |> FormParams.put_emptied_selections()
      |> FormAttachments.carry_uploaded_attachments(socket.assigns.form)

    case AttachmentKeys.validate_issued(socket.assigns.form, params, socket) do
      {params, form} -> submit_form(form, params, socket)
      :refused -> {:halt, put_flash(socket, :error, ActionErrors.forbidden_message())}
    end
  end

  defp handle_open_form_events(_, _, socket, _options), do: {:cont, socket}

  defp submit_form(form, params, socket) do
    # What this post hides takes no upload: the state it builds is what the
    # save consults before it stores any file.
    socket =
      assign(socket, ash_quick_form_state: FormStateFlow.build(form, :submit, socket))

    # A socket upload the store refuses at save is left out and the save goes
    # on, as it would had the file never been picked; the flash says so, so an
    # update keeping its old file is not read as the new one saved.
    {upload_params, {refused, stored_keys}} =
      params
      |> FormParams.maybe_put_nested_params(form)
      |> FormParams.maybe_put_has_many(form)
      |> FormAttachments.upload_images(socket, form)

    # A socket upload's key is made here, as the save consumes the entry. A
    # save that fails leaves it in the form — a sub-form's rides its hidden
    # input — so the next post names it back, and the form must know it issued
    # it.
    socket =
      stored_keys
      |> Enum.reduce(socket, fn {key, upload_name}, socket ->
        AttachmentKeys.mint_attachment_key(socket, key, upload_name)
      end)
      |> FormAttachments.flash_failed_uploads(refused)

    # The post the save runs is the one just made, less what the state built
    # from it hides, and a field the state requires is held to it here: Ash
    # knows nothing of either. It is validated under the submit stage, and
    # the save runs the form as it settles, so the post is validated once.
    {_params, checked, state} =
      form
      |> put_stage(AshQuick.form_submit_stage())
      |> then(
        &FormStateFlow.settle(
          &1,
          upload_params,
          AshPhoenix.Form.validate(&1, upload_params, errors: false),
          :submit,
          socket,
          errors: false
        )
      )

    case submit(checked, state, socket) do
      {:refused, refused} ->
        {:halt,
         socket
         |> assign(form: put_stage(refused, AshQuick.form_validate_stage()))
         |> FormStateFlow.store(:validate)}

      result ->
        run_submit(result, state, params, socket)
    end
  end

  defp run_submit(result, state, params, socket) do
    socket = socket |> PrintUtils.print(result) |> DownloadUtils.deliver(result)

    case result do
      {:ok, rec} ->
        socket = assign(socket, ash_quick_minted_attachment_keys: %{})
        handle_success(rec, params, socket.assigns.ash_action.name, socket)

      # Every message below comes from `AshQuick.LiveView.ActionErrors`, which
      # owns what a failed action says to a person. Spelling one out here is how
      # the same condition ends up worded two ways depending on which surface
      # hit it — and how `Ash.Error.error_descriptions/1`, a debug dump of the
      # error class and its bread crumbs, ends up in a toast.
      {:error, %{source: %{errors: [%Ash.Error.Changes.StaleRecord{} = error]}}} ->
        log_failed_save(socket, fn -> "the record changed since it was loaded" end)

        {:halt, put_flash(socket, :error, ActionErrors.user_facing_message(error))}

      {:error, form} ->
        log_failed_save(socket, fn -> FormSaveErrors.describe_failed_save(form) end)

        case FormSaveErrors.input_errors(form) do
          # Nothing to say about any input, on the form or any sub-form: the
          # failure is said as every other surface says it. A policy refusing
          # the save is worded as one, in the policy's own words when it has
          # some, and nothing else is.
          [] ->
            {:halt, put_flash(socket, :error, FormSaveErrors.failed_save_message(form))}

          # The form stays open, so its next validate runs under the validate
          # stage. An error on a field the state the save ran with holds back
          # has no input on the page, so it is flashed.
          _errors ->
            socket =
              FormSaveErrors.flash_unplaced_errors(
                socket,
                form,
                Map.get(socket.assigns, :scope),
                state
              )

            {:halt,
             socket
             |> assign(form: put_stage(form, AshQuick.form_validate_stage()))
             |> FormStateFlow.store(:validate)}
        end
    end
  end

  # Timed as `[:ash_quick, :form, :submit]` (see `AshQuick.Telemetry`). A
  # field `require/3` marks that is blank refuses the save before the action
  # runs, as `{:refused, form}`, and counts as an `:error`. `form` was
  # validated with the post already, under the submit stage, so the submit
  # does not validate it again.
  defp submit(form, state, socket) do
    scope = Map.get(socket.assigns, :scope)

    AshQuick.Telemetry.span(
      [:form, :submit],
      %{
        quick_view: socket.view,
        resource: form.resource,
        action: form.action,
        type: form.type,
        scope: scope
      },
      fn ->
        result =
          case FormStateFlow.enforce(state, form) do
            :ok ->
              AshPhoenix.Form.submit(form,
                params: nil,
                before_submit: &FormAttachments.reference_attachments(&1, scope),
                action_opts: action_opts(form)
              )

            {:error, refused} ->
              {:refused, refused}
          end

        {result, %{result: if(match?({:ok, _}, result), do: :ok, else: :error)}}
      end
    )
  end

  # A destroy hands back the record it destroyed only when asked to, and
  # everything after the submit — the print, where to go next — reads it.
  defp action_opts(%AshPhoenix.Form{type: :destroy}),
    do: [context: run_context(), return_destroyed?: true]

  defp action_opts(_form), do: [context: run_context()]

  defp run_context do
    AshQuick.form_submit_stage()
    |> stage_context()
    |> Map.put(:action_source, AshQuick.form_source())
  end

  defp stage_context(stage), do: %{AshQuick.form_stage_key() => stage}

  # `AshPhoenix.Form.validate/3` rebuilds the changeset with the context the
  # form was built with, and `submit/2` builds the one it runs the same way,
  # running the action's changes there; the run's own `context` is merged in
  # only after them. So the stage rides in the form's build options, which
  # every changeset the form builds is given.
  defp put_stage(form, stage) do
    context = stage_context(stage)

    AshPhoenix.Form.update_options(
      form,
      &Keyword.update(&1, :context, context, fn held -> Map.merge(held, context) end)
    )
  end

  # `JS.push/2` sends the position as a number, a `phx-value-index` as a string.
  defp attachment_position(index) when is_integer(index) and index >= 0, do: {:ok, index}

  defp attachment_position(index) when is_binary(index) do
    case Integer.parse(index) do
      {position, ""} when position >= 0 -> {:ok, position}
      _not_a_position -> :error
    end
  end

  defp attachment_position(_index), do: :error

  # A refused save is an outcome the person was already shown, not an incident,
  # so it is told at debug — and only as *what* failed. Never the params, the
  # form, its changeset, the record, the actor or an error struct: each carries
  # what was submitted, and an error's message can interpolate it from `vars`.
  # Field names, the resource and action, and error modules are all it says.
  defp log_failed_save(socket, describe) do
    Logger.debug(fn ->
      "form save on #{inspect(socket.assigns.form.resource)}.#{socket.assigns.ash_action.name} " <>
        "refused: #{describe.()}"
    end)
  end

  # A destroy returns to the page it was opened from, unless that page was
  # the record it destroyed: then to the list.
  # Matched on the record the page showed, not the id in its URL: that is the
  # id as typed, and an upper-cased UUID loads the same record without being
  # equal to it. Only on a details page, since a list the socket patched to
  # from one still holds that record. A full page reached with nothing before
  # it names the record's page without having read it, at the id this page's
  # own URL typed.
  defp handle_success(
         %{id: id},
         _form_params,
         _action,
         %{assigns: %{ash_action: %{type: :destroy}}} = socket
       ) do
    list_path =
      URLParams.full_path(
        socket.assigns.base_path,
        URLParams.to_list_params(socket.assigns.params)
      )

    url_id = socket.assigns.params.id

    path =
      case socket.assigns.ash_quick_background do
        %{params: %URLParams{id: shown}, record: %{id: ^id}} when shown != nil ->
          list_path

        %{params: %URLParams{id: ^url_id}, record: nil} ->
          list_path

        %{path: path} ->
          path

        nil ->
          list_path
      end

    {:halt,
     socket |> put_flash(:info, gettext("Record deleted successfully")) |> push_patch(to: path)}
  end

  # An update returns to the page it was opened from, which reloads to show
  # it. A create goes on to the record it made: the next thing anyone does
  # with it is there.
  defp handle_success(
         _record,
         _form_params,
         _action,
         %{assigns: %{ash_action: %{type: :update}, ash_quick_background: %{path: path}}} = socket
       ) do
    {:halt,
     socket |> put_flash(:info, gettext("Record saved successfully")) |> push_patch(to: path)}
  end

  defp handle_success(record, _form_params, _action, socket) do
    %{base_path: base_path, params: params} = socket.assigns

    details_params = params |> URLParams.to_details_params(record.id)
    details_path = URLParams.full_path(base_path, details_params)

    {:halt,
     socket
     |> put_flash(:info, gettext("Record saved successfully"))
     |> push_patch(to: details_path)}
  end
end
