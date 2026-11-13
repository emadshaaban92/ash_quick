defmodule AshQuick.LiveView.FormUtils do
  @moduledoc false
  require Ash.Query
  require Logger
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2, assign: 3]
  use Gettext, backend: AshQuick.Gettext
  alias AshQuick.Labels
  alias AshQuick.LiveView.ActionErrors
  alias AshQuick.LiveView.EnumOptions
  alias AshQuick.LiveView.FieldErrors
  alias AshQuick.LiveView.DownloadUtils
  alias AshQuick.LiveView.PrintUtils
  alias AshQuick.LiveView.URLParams
  alias AshQuick.LiveView.QuickView.Options
  alias Ash.Resource.Actions.Argument
  alias Ash.Type
  alias AshQuick.LiveView.Components.FormView
  alias AshQuick.LiveView.DetailsUtils
  alias AshQuick.LiveView.ListUtils
  alias AshQuick.LiveView.Utils
  alias AshQuick.Storage

  # The name each sub-form's uploads were allowed under (`upload_name/3`).
  @upload_names :ash_quick_upload_names

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
    |> then(&allow_image_upload(&1, &1.assigns.form))
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
        transform_params: &transform_nested_params/3,
        transform_errors: &ActionErrors.renderable_vars/2,
        scope: socket.assigns.scope,
        actor: actor(socket),
        context: stage_context(AshQuick.form_build_stage())
      )
      |> then(&add_nested_forms(&1, &1.form_keys))
      |> opened()

    socket |> assign(form: form) |> assign_issued_attachment_keys()
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
        transform_params: &transform_nested_params/3,
        transform_errors: &ActionErrors.renderable_vars/2,
        scope: socket.assigns.scope,
        actor: actor(socket),
        context: stage_context(AshQuick.form_build_stage())
      )
      |> opened()

    socket |> assign(form: form) |> assign_issued_attachment_keys()
  end

  # A field a field policy hides on the record gets no sub-form: Ash read it
  # as `%Ash.ForbiddenField{}`, which there is nothing to build one over. See
  # `Utils.form_fields/1`, which keeps every other path off it.
  defp set_form(socket, :update, _options) do
    %{record: record, resource: resource, ash_action: %{name: action}} = socket.assigns

    form =
      AshPhoenix.Form.for_update(record, action,
        forms: Utils.nested_forms(resource, action, Utils.hidden_field_names(record)),
        transform_params: &transform_nested_params/3,
        transform_errors: &ActionErrors.renderable_vars/2,
        scope: socket.assigns.scope,
        actor: actor(socket),
        context: stage_context(AshQuick.form_build_stage())
      )
      |> then(&add_nested_forms(&1, &1.form_keys))
      |> prefill_form_has_many_args(socket)
      |> prefill_changed_embedded_forms()
      |> opened()

    socket |> assign(form: form) |> assign_issued_attachment_keys()
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

  # The attachment keys this form will take from a post, per top-level field:
  # what the form held in that field when it was built, read off the form
  # itself rather than the page's `record` assign, which a create form reached
  # by a patch still carries from the page before. That covers the record's
  # own values (`form.data`), what the action's changes put there before anyone
  # touched it (a seeded embed, say), and every sub-form under the field — an
  # embed's, or a related record's under a managed relationship. Keyed by field
  # so a key cannot move between fields of the same visibility: out of one the
  # actor cannot see or the action does not accept, into one it can.
  #
  # Keys this page mints for an upload are held apart, in
  # `ash_quick_minted_attachment_keys`, each with the top-level field whose
  # upload made it (`mint_attachment_key/3`). They belong to this form, so a
  # new form starts without any, as it does after a save: a key uploaded for
  # one record must not be taken into the next. So do the single attachments
  # this form's ✕ emptied (`kept_attachment/4`).
  defp assign_issued_attachment_keys(socket) do
    socket
    |> assign(
      ash_quick_issued_attachment_keys: attachment_keys_by_field(socket.assigns.form, true)
    )
    |> assign(ash_quick_minted_attachment_keys: %{})
    |> assign(@upload_names, %{})
    |> assign(ash_quick_cleared_attachments: MapSet.new())
  end

  # Every attachment key a form holds, by the top-level field it sits under.
  # `with_data?` adds what the forms' records already store; without it this is
  # only what the forms would write, which is what a post can have put there.
  defp attachment_keys_by_field(form, with_data?) do
    own =
      form
      |> form_values(with_data?)
      |> Enum.map(fn {field, value} -> {field, MapSet.new(Storage.keys_in(value))} end)

    nested =
      for {field, forms} <- form.forms, do: {field, subtree_attachment_keys(forms, with_data?)}

    Enum.reduce(own ++ nested, %{}, fn {field, keys}, acc ->
      Map.update(acc, field, keys, &MapSet.union(&1, keys))
    end)
  end

  defp subtree_attachment_keys(forms, with_data?) do
    forms
    |> List.wrap()
    |> Enum.map(&attachment_keys_by_field(&1, with_data?))
    |> Enum.flat_map(&Map.values/1)
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
  end

  defp form_values(form, with_data?) do
    stored = if with_data?, do: record_values(form.data), else: []
    source = form.source

    stored ++
      Enum.to_list(Map.get(source, :attributes, %{})) ++
      Enum.to_list(Map.get(source, :arguments, %{}))
  end

  defp record_values(%resource{} = record) do
    if Ash.Resource.Info.resource?(resource) do
      resource
      |> Ash.Resource.Info.attributes()
      |> Enum.map(&{&1.name, Map.get(record, &1.name)})
    else
      []
    end
  end

  defp record_values(_no_record), do: []

  # A key is minted for the field its upload belongs to, read off the upload's
  # name: whatever sub-form it sits on, the first segment after the root
  # form's name is the top-level field (`upload_name/3`). Each key is recorded
  # where it is made, so it does not matter which path consumes the entry.
  defp mint_attachment_key(%Phoenix.LiveView.Socket{} = socket, key, upload_name) do
    minted = Map.get(socket.assigns, :ash_quick_minted_attachment_keys, %{})
    field = upload_field(socket.assigns[:form], upload_name)
    assign(socket, ash_quick_minted_attachment_keys: Map.put(minted, key, field))
  end

  # Called outside a LiveView there is no form to take the key back.
  defp mint_attachment_key(socket, _key, _upload_name), do: socket

  defp upload_field(%{name: root}, upload_name) when is_binary(root) do
    prefix = root <> "["

    with ^prefix <> rest <- to_string(upload_name),
         [field, _rest] <- String.split(rest, "]", parts: 2) do
      field
    else
      _not_a_form_upload -> nil
    end
  end

  defp upload_field(_no_form, _upload_name), do: nil

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

  defp transform_nested_params(form, params, _) do
    form
    |> keep_blank_secrets(params)
    |> transform_nested_form_params(form)
  end

  # The input for a `sensitive?` field never shows the stored value, so on an
  # update a blank one means "unchanged", not "clear it".
  defp keep_blank_secrets(%{type: :update, resource: resource, action: action}, params) do
    resource
    |> sensitive_inputs(action)
    |> Enum.reduce(params, fn name, acc ->
      key = to_string(name)
      if Map.get(acc, key) == "", do: Map.delete(acc, key), else: acc
    end)
  end

  defp keep_blank_secrets(_form, params), do: params

  defp sensitive_inputs(resource, action) do
    case Ash.Resource.Info.action(resource, action) do
      nil ->
        []

      action ->
        accepted =
          for name <- action.accept,
              AshQuick.Info.sensitive?(resource, name),
              do: name

        accepted ++ for(%{sensitive?: true, name: name} <- action.arguments, do: name)
    end
  end

  defp transform_nested_form_params(params, form) do
    form.form_keys
    |> Enum.reduce(params, fn {field_name, form_key}, params_acc ->
      case form_key[:type] do
        :single ->
          handle_empty_nested(params_acc, field_name |> to_string())

        :list ->
          params_acc |> Map.put_new(field_name |> to_string(), %{})
      end
    end)
  end

  defp handle_empty_nested(params, field_name) when is_binary(field_name) do
    case Map.get(params, field_name) do
      %{"_form_type" => _, "_persistent_id" => _} = param_value ->
        param_value =
          param_value
          |> Map.drop(["_form_type", "_persistent_id", "_touched"])

        if param_value |> Map.values() |> Enum.any?(&(&1 != "")) do
          params
        else
          params |> Map.put(field_name |> to_string(), nil)
        end

      _ ->
        params
    end
  end

  defp prefill_form_has_many_args(form, socket) do
    AshPhoenix.Form.arguments(form)
    |> Enum.reduce(form, fn arg, form_acc ->
      prefill_form_has_many_arg(form_acc, socket.assigns.resource, arg)
    end)
  end

  defp prefill_form_has_many_arg(form, resource, arg) do
    with %{destination: _, name: name} <-
           Utils.argument_to_relationship(arg, resource, form.action),
         records when is_list(records) <- Map.get(form.data, name) do
      value = Enum.map(records, & &1.id)
      form |> AshPhoenix.Form.update_params(&Map.put(&1, arg.name, value))
    else
      _ -> form
    end
  end

  # A change module on the action may seed an embedded attribute onto the
  # changeset before submission. AshPhoenix builds embedded sub-forms from the
  # loaded record (`changeset.data`), not from the change, so such a seeded
  # value is not reflected in the form. Re-seed those sub-forms from the
  # changeset's current value via params: this leaves `changeset.data` untouched
  # (so anything captured from it on submit stays correct), and a real upload
  # still overrides the prefilled value. Scalar fields already prefill because
  # their value resolves through the changeset's changes.
  # `carried` is merged under the seeded values, so re-seeding keeps whatever the
  # caller has already typed. It is empty when the form is first built, which is
  # the only point at which there is nothing to keep.
  defp prefill_changed_embedded_forms(form, carried \\ %{}) do
    seeded =
      form.form_keys
      |> Enum.flat_map(fn {field, config} ->
        case embedded_change_params(form.source, field, config[:type]) do
          :no_change -> []
          {:ok, params} -> [{field |> to_string(), params}]
        end
      end)
      |> Map.new()

    if map_size(seeded) == 0 do
      form
    else
      AshPhoenix.Form.validate(form, Map.merge(carried, seeded), errors: false)
    end
  end

  defp embedded_change_params(%Ash.Changeset{} = changeset, field, type)
       when type in [:list, :single] do
    with {:ok, value} <- Map.fetch(changeset.attributes, field),
         %{type: attr_type} <- Ash.Resource.Info.attribute(changeset.resource, field),
         true <- Ash.Type.embedded_type?(attr_type) do
      {:ok, embedded_to_params(value)}
    else
      _ -> :no_change
    end
  end

  defp embedded_change_params(_changeset, _field, _type), do: :no_change

  defp embedded_to_params(values) when is_list(values) do
    Enum.map(values, &embedded_struct_to_params/1)
  end

  defp embedded_to_params(value), do: embedded_struct_to_params(value)

  defp embedded_struct_to_params(nil), do: %{}

  defp embedded_struct_to_params(%resource{} = struct) do
    Ash.Resource.Info.public_attributes(resource)
    |> Map.new(fn attr ->
      {attr.name |> to_string(), encode_embedded_value(Map.get(struct, attr.name), attr.type)}
    end)
  end

  # Attachment values are carried through the form as the JSON the upload
  # widget's hidden input submits, so a prefilled attachment round-trips on
  # save exactly like a freshly-uploaded one.
  defp encode_embedded_value(nil, _type), do: nil

  defp encode_embedded_value(%AshQuick.AshTypes.Attachment.Value{} = value, _type) do
    Jason.encode!(value)
  end

  defp encode_embedded_value(values, {:array, AshQuick.AshTypes.Attachment})
       when is_list(values) do
    Enum.map(values, &Jason.encode!/1)
  end

  defp encode_embedded_value(value, type) do
    if Ash.Type.embedded_type?(type) do
      embedded_to_params(value)
    else
      value
    end
  end

  defp allow_image_upload(socket, nil), do: socket

  defp allow_image_upload(socket, form) do
    socket |> name_sub_form_uploads(form) |> allow_form_uploads(form, true)
  end

  defp allow_form_uploads(socket, forms, root?) when is_list(forms) do
    Enum.reduce(forms, socket, &allow_form_uploads(&2, &1, root?))
  end

  defp allow_form_uploads(socket, nil, _root?), do: socket

  defp allow_form_uploads(socket, form, root?) do
    Utils.form_fields(form)
    |> Enum.reduce(socket, &maybe_allow_upload(form, &1, &2, root?))
    |> then(
      &Enum.reduce(form.forms |> Map.values(), &1, fn nested_form, socket_acc ->
        allow_form_uploads(socket_acc, nested_form, false)
      end)
    )
  end

  defp maybe_allow_upload(form, field, socket, root?)
       when field.type in [
              AshQuick.AshTypes.Attachment,
              {:array, AshQuick.AshTypes.Attachment}
            ] do
    upload_name = upload_name(socket.assigns, form, field)

    case socket.assigns[:uploads][upload_name] do
      nil ->
        constraints = attachment_constraints(field)
        accepts = Keyword.fetch!(constraints, :accepts)

        allow_upload(
          socket,
          upload_name,
          [
            accept: attachment_accept_extensions(accepts),
            max_entries: if(field.type == AshQuick.AshTypes.Attachment, do: 1, else: 10),
            max_file_size: attachment_max_bytes(constraints),
            auto_upload: true,
            validator: &validate_attachment_entry(&1, constraints),
            progress: upload_progress_handler(upload_name, field, constraints, root?)
          ] ++ upload_transport(constraints)
        )

      _ ->
        socket
    end
  end

  defp maybe_allow_upload(_form, _field, socket, _root?), do: socket

  # A sub-form's name is its position — `form[images][2]` — and removing a row
  # renumbers every row after it. An upload keeps the name it was allowed
  # under, and with it whatever was picked into it, so naming a sub-form's
  # upload after the sub-form's current name would save the removed row's file
  # onto the row that took its place, and look for a later row's file under a
  # name no row has any more. So each sub-form keeps the name its uploads were
  # allowed under: `ash_quick_upload_names` maps a sub-form's current name to
  # it, wherever the two differ. A form built anew starts without any
  # (`assign_issued_attachment_keys/1`).

  defp upload_name(assigns, form, field) do
    names = Map.get(assigns, @upload_names, %{})
    "#{Map.get(names, form.name, form.name)}[#{field.name}]_upload"
  end

  @doc false
  # The page's `@uploads` as the form reads them: each under the name of the
  # field it belongs to now, `"#{phx_field.name}_upload"`, which is how the
  # built-in inputs, a custom template and a widget all look one up.
  def with_upload_names(%{@upload_names => names, uploads: %{} = uploads} = assigns)
      when map_size(names) > 0 do
    aliased =
      for {current, held} <- names,
          {name, config} when is_binary(name) <- uploads,
          field = field_of_upload(name, held),
          field != nil,
          into: uploads,
          do: {"#{current}[#{field}]_upload", config}

    assign(assigns, :uploads, aliased)
  end

  def with_upload_names(assigns), do: assigns

  # The field an upload named under `prefix` belongs to, when it is one of that
  # sub-form's own fields rather than one of a sub-form below it.
  defp field_of_upload(name, prefix) do
    with ^prefix <> "[" <> rest <- name,
         [field] <- Regex.run(~r/^([^\[\]]+)\]_upload$/, rest, capture: :all_but_first) do
      field
    else
      _not_its_own -> nil
    end
  end

  # A sub-form new to this page takes its own name for its uploads, unless a
  # row renumbered onto that name still holds it; then it takes a name no
  # upload has been allowed under yet.
  defp name_sub_form_uploads(socket, form) do
    form
    |> sub_forms()
    |> Enum.reduce(socket, fn sub_form, socket ->
      names = Map.get(socket.assigns, @upload_names, %{})
      held = names |> Map.values() |> MapSet.new()

      if Map.has_key?(names, sub_form.name) or not MapSet.member?(held, sub_form.name) do
        socket
      else
        name = unused_upload_prefix(socket, held, sub_form.name, 1)
        assign(socket, @upload_names, Map.put(names, sub_form.name, name))
      end
    end)
  end

  defp unused_upload_prefix(socket, held, name, n) do
    candidate = "#{name}_#{n}"
    allowed = Map.keys(socket.assigns[:uploads] || %{})

    if MapSet.member?(held, candidate) or
         Enum.any?(allowed, &(is_binary(&1) and String.starts_with?(&1, candidate <> "["))),
       do: unused_upload_prefix(socket, held, name, n + 1),
       else: candidate
  end

  # Every sub-form under `form`, at any depth.
  defp sub_forms(form) do
    form.forms
    |> Map.values()
    |> Enum.flat_map(&List.wrap/1)
    |> Enum.flat_map(&[&1 | sub_forms(&1)])
  end

  # After `remove-form`: the removed sub-form's picks are cancelled, so a row
  # later given its name starts empty, and every sub-form left keeps the
  # uploads it had under whatever name it has now.
  defp follow_removed_sub_form(socket, held, form, path) do
    if AshPhoenix.Form.has_form?(held, path) do
      removed = sub_form_at(held, AshPhoenix.Form.parse_path!(held, path))
      {pairs, gone} = pair_sub_forms(held, form, removed.name)
      names = Map.get(socket.assigns, @upload_names, %{})

      kept =
        for {before, now} <- pairs,
            name = Map.get(names, before, before),
            name != now,
            into: %{},
            do: {now, name}

      gone
      |> Enum.reduce(socket, &cancel_sub_form_uploads(&2, &1))
      |> assign(@upload_names, kept)
      |> name_sub_form_uploads(form)
    else
      socket
    end
  end

  defp sub_form_at(form, []), do: form

  defp sub_form_at(form, [field, index | path]) when is_integer(index),
    do: form.forms |> Map.fetch!(field) |> Enum.at(index) |> sub_form_at(path)

  defp sub_form_at(form, [field | path]), do: form.forms |> Map.fetch!(field) |> sub_form_at(path)

  # Each sub-form of `held` with the one it is in `form` — the same rows, in
  # the same order, less the removed one — and every sub-form that went with
  # the removed one.
  defp pair_sub_forms(held, form, removed) do
    Enum.reduce(held.forms, {[{held.name, form.name}], []}, fn {field, held_sub}, acc ->
      now = Map.get(form.forms, field)

      {kept, gone} =
        held_sub
        |> List.wrap()
        |> Enum.split_with(&(&1.name != removed))

      pairs = Enum.zip(kept, List.wrap(now))
      unpaired = Enum.drop(kept, length(pairs))

      Enum.reduce(pairs, add_gone(acc, gone ++ unpaired), fn {held_sub, now}, {p, g} ->
        {more_pairs, more_gone} = pair_sub_forms(held_sub, now, removed)
        {more_pairs ++ p, more_gone ++ g}
      end)
    end)
  end

  defp add_gone({pairs, gone}, forms),
    do: {pairs, Enum.flat_map(forms, &[&1 | sub_forms(&1)]) ++ gone}

  defp cancel_sub_form_uploads(socket, form) do
    Utils.form_fields(form)
    |> Enum.filter(
      &(&1.type in [AshQuick.AshTypes.Attachment, {:array, AshQuick.AshTypes.Attachment}])
    )
    |> Enum.reduce(socket, fn field, socket ->
      name = upload_name(socket.assigns, form, field)

      case socket.assigns[:uploads][name] do
        %{entries: entries} ->
          Enum.reduce(entries, socket, &cancel_upload(&2, name, &1.ref))

        nil ->
          socket
      end
    end)
  end

  # A storage module that names an upload target has the browser write to it;
  # one that does not takes the bytes over the socket (`AshQuick.Storage`,
  # "Browser uploads").
  defp upload_transport(constraints) do
    case Storage.upload_mode() do
      :external ->
        [external: fn entry, socket -> presign_attachment_upload(entry, socket, constraints) end]

      :socket ->
        []
    end
  end

  # A field on a nested sub-form is left to the save path: its params live under
  # a path this handler has no way to address from the root form.
  defp upload_progress_handler(_upload_name, _field, _constraints, false) do
    fn _name, _entry, socket -> {:noreply, socket} end
  end

  # `auto_upload: true` means the bytes are already in the store by the time the
  # last entry reports done — the form just does not know about them until a
  # save consumes them. Consuming here instead puts them into the form's params
  # as soon as they land, so a field the action folds into an attribute (an
  # `add_*` argument over an embedded array, say) shows its images straight
  # away rather than only after a save.
  defp upload_progress_handler(upload_name, field, constraints, true) do
    fn _name, _entry, socket ->
      {:noreply, consume_completed_upload(socket, upload_name, field, constraints)}
    end
  end

  defp consume_completed_upload(socket, upload_name, field, constraints) do
    entries = valid_entries(socket, upload_name)

    if entries != [] and Enum.all?(entries, & &1.done?) do
      {values, failed} = consume_attachment_entries(socket, upload_name, constraints)

      # A socket upload's key is made here rather than at presign, so this is
      # where the form learns it issued it.
      values
      |> Enum.reduce(socket, &mint_attachment_key(&2, &1["key"], upload_name))
      |> put_uploaded_values(field, values)
      |> flash_refused_upload(failed)
    else
      socket
    end
  end

  # Validating with params that omit an embedded field clears it, and the params
  # this fold starts from are whatever the caller last submitted — which on a
  # page nothing has changed yet is nothing at all. Every embedded field the
  # params do not restate is carried over from the changeset so the fold cannot
  # drop what is already there.
  defp carry_embedded_params(params, form) do
    Enum.reduce(form.form_keys, params, fn {field, config}, acc ->
      key = field |> to_string()

      with false <- Map.has_key?(acc, key),
           true <- config[:type] in [:list, :single],
           %{type: attr_type} <- Ash.Resource.Info.attribute(form.resource, field),
           true <- Ash.Type.embedded_type?(attr_type) do
        value = Ash.Changeset.get_attribute(form.source, field)
        Map.put(acc, key, embedded_to_params(value))
      else
        _not_a_carried_embed -> acc
      end
    end)
  end

  defp put_uploaded_values(socket, _field, []), do: socket

  defp put_uploaded_values(socket, field, values) do
    form = socket.assigns.form
    held = if held_attachments?(field), do: held_attachments(form, field)

    put_field_value(socket, field, fold_uploaded_values(field, held, values))
  end

  # Validates the form with `value` as the field's params and everything else
  # it already holds.
  defp put_field_value(socket, field, value) do
    form = socket.assigns.form
    key = field.name |> to_string()
    raw_params = form.raw_params || %{}

    # The field's own params are folded into `value` by the caller, so they must
    # not survive into the re-seed as well — they would be applied a second time.
    carried = raw_params |> Map.delete(key) |> carry_embedded_params(form)

    form =
      form
      |> AshPhoenix.Form.validate(Map.put(carried, key, value))
      |> prefill_changed_embedded_forms(carried)

    # Folding the values in can create sub-forms — an embedded array grows a
    # form per image — and each one's own attachment field needs its upload
    # registered before a save goes looking for it.
    socket |> assign(form: form) |> allow_image_upload(form)
  end

  # This batch consumed its entries, so from here the field's params are the
  # only record of a batch picked before it. Whether they belong under this one
  # is the field's own question:
  #
  # - A single-valued field has nothing to keep — the file just picked is the
  #   value, replacing whatever the last pick left.
  # - An argument the action folds somewhere else (`add_images` onto `:images`)
  #   is spent as it folds. Carrying its params would attach that batch twice.
  # - An array attribute — `ReturnRequest.attachments` — keeps them, and this
  #   batch lands after them. Picking twice has to read like picking both at
  #   once, or the earlier files are dropped with nothing on the page to say so.
  #   What it keeps is `held_attachments/2`: on an update form that starts as
  #   the record's own list, so the first batch lands after the stored files
  #   rather than in place of them.
  defp fold_uploaded_values(%{type: AshQuick.AshTypes.Attachment}, _held, [value | _]), do: value

  defp fold_uploaded_values(%Argument{}, _held, values), do: values

  defp fold_uploaded_values(_attribute, held, values) when is_list(held), do: held ++ values

  defp fold_uploaded_values(_attribute, _nothing_held, values), do: values

  defp attachment_constraints(%{type: AshQuick.AshTypes.Attachment, constraints: c}), do: c || []

  defp attachment_constraints(%{type: {:array, AshQuick.AshTypes.Attachment}, constraints: c}) do
    (c || []) |> Keyword.get(:items, [])
  end

  @default_max_size_mb 50

  defp attachment_max_bytes(constraints),
    do: Keyword.get(constraints, :max_size_mb, @default_max_size_mb) * 1024 * 1024

  # The extensions each media class takes, with the type every surface stores
  # and serves the object as. The type comes from here, not from the browser:
  # what an entry declares is whatever the picker was told, and a name ending
  # `.html` declared `image/jpeg` is still an HTML page to anything that serves
  # it by its key.
  @attachment_media_types %{
    image: [
      {".jpg", "image/jpeg"},
      {".jpeg", "image/jpeg"},
      {".png", "image/png"},
      {".webp", "image/webp"}
    ],
    video: [{".mp4", "video/mp4"}, {".mov", "video/quicktime"}, {".webm", "video/webm"}],
    document: [{".pdf", "application/pdf"}]
  }

  defp attachment_media_types(accepts) do
    Enum.flat_map(accepts, &Map.get(@attachment_media_types, &1, []))
  end

  defp attachment_accept_extensions(accepts) do
    accepts |> attachment_media_types() |> Enum.map(&elem(&1, 0))
  end

  # `allow_upload/3`'s `accept:` is not enough on its own: LiveView passes an
  # entry when its declared type *or* its name matches, and both are the
  # browser's to say. The name is what the key is built from, so the name is
  # what is checked. LiveView runs this on the server for every entry, before
  # it is presigned and before any of its bytes are sent over the socket.
  defp validate_attachment_entry(entry, constraints) do
    if accepted_media_type(entry, constraints), do: :ok, else: {:error, :not_accepted}
  end

  # The media type for an entry whose name the field accepts, or `nil`.
  defp accepted_media_type(entry, constraints) do
    ext = entry.client_name |> safe_filename() |> Path.extname()

    constraints
    |> Keyword.get(:accepts, [])
    |> attachment_media_types()
    |> List.keyfind(ext, 0, {ext, nil})
    |> elem(1)
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
    {:halt, socket |> assign(form: form) |> allow_image_upload(form) |> clear_form_flash()}
  end

  defp handle_open_form_events("remove-form", %{"path" => path}, socket, _options) do
    held = socket.assigns.form
    form = AshPhoenix.Form.remove_form(held, path)

    {:halt,
     socket
     |> follow_removed_sub_form(held, form, path)
     |> assign(form: form)
     |> clear_form_flash()}
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
    case clearable_attachment_field(socket.assigns.form, name) do
      %{} = field ->
        cleared = Map.get(socket.assigns, :ash_quick_cleared_attachments, MapSet.new())

        {:halt,
         socket
         |> assign(ash_quick_cleared_attachments: MapSet.put(cleared, field.name))
         |> put_field_value(field, nil)
         |> clear_flash()}

      nil ->
        {:halt, socket}
    end
  end

  defp handle_open_form_events("remove-attachment", params, socket, _options) do
    form = socket.assigns.form

    with %{"field" => name, "index" => index} when is_binary(name) <- params,
         %{} = field <- held_attachments_field(form, name),
         {:ok, position} <- attachment_position(index),
         held when is_list(held) and position < length(held) <- held_attachments(form, field) do
      {:halt, socket |> put_field_value(field, List.delete_at(held, position)) |> clear_flash()}
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
      |> put_emptied_selections()
      |> carry_uploaded_attachments(socket.assigns.form)
      |> maybe_put_has_many(socket.assigns.form)

    case validate_issued(socket.assigns.form, params, socket) do
      {_params, form} -> {:halt, socket |> assign(form: form) |> clear_form_flash()}
      :refused -> {:halt, socket}
    end
  end

  defp handle_open_form_events("save", %{"form" => params}, socket, _options) do
    params = params |> put_emptied_selections() |> carry_uploaded_attachments(socket.assigns.form)

    case validate_issued(socket.assigns.form, params, socket) do
      {params, form} -> submit_form(form, params, socket)
      :refused -> {:halt, put_flash(socket, :error, ActionErrors.forbidden_message())}
    end
  end

  defp handle_open_form_events(_, _, socket, _options), do: {:cont, socket}

  defp submit_form(form, params, socket) do
    # A socket upload the store refuses at save is left out and the save goes
    # on, as it would had the file never been picked; the flash says so, so an
    # update keeping its old file is not read as the new one saved.
    {upload_params, {refused, stored_keys}} =
      params
      |> maybe_put_nested_params(form)
      |> maybe_put_has_many(form)
      |> upload_images(socket, form)

    # A socket upload's key is made here, as the save consumes the entry. A
    # save that fails leaves it in the form — a sub-form's rides its hidden
    # input — so the next post names it back, and the form must know it issued
    # it.
    socket =
      stored_keys
      |> Enum.reduce(socket, fn {key, upload_name}, socket ->
        mint_attachment_key(socket, key, upload_name)
      end)
      |> flash_failed_uploads(refused)

    result =
      form
      |> put_stage(AshQuick.form_submit_stage())
      |> AshPhoenix.Form.submit(
        params: upload_params,
        before_submit: &reference_attachments(&1, Map.get(socket.assigns, :scope)),
        action_opts: action_opts(form)
      )

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
        log_failed_save(socket, fn -> describe_failed_save(form) end)

        case input_errors(form) do
          # Nothing to say about any input, on the form or any sub-form: the
          # failure is said as every other surface says it. A policy refusing
          # the save is worded as one, in the policy's own words when it has
          # some, and nothing else is.
          [] ->
            {:halt, put_flash(socket, :error, failed_save_message(form))}

          # The form stays open, so its next validate runs under the validate stage.
          _errors ->
            socket = flash_unplaced_errors(socket, form, Map.get(socket.assigns, :scope))
            {:halt, assign(socket, form: put_stage(form, AshQuick.form_validate_stage()))}
        end
    end
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

  defp describe_failed_save(form) do
    case input_errors(form) do
      [] ->
        modules =
          form
          |> raw_errors()
          |> Enum.map_join(", ", fn
            %module{} -> inspect(module)
            _not_a_struct -> "an unstructured error"
          end)

        "no field errors, the action returned [#{modules}]"

      errors ->
        "errors on fields #{errors |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.join(", ")}"
    end
  end

  # Every input error on the form and its sub-forms, each named by its field
  # under the path of the form it is on (`items[0].status`). An error a
  # sub-form's changeset refuses is filed on that sub-form, never on the root,
  # so the root's own errors miss it: AshPhoenix walks the whole tree for them.
  defp input_errors(form) do
    form
    |> AshPhoenix.Form.errors(for_path: :all)
    |> Enum.flat_map(fn {path, errors} ->
      Enum.map(errors, fn {field, message} -> {field_path(path, field), message} end)
    end)
  end

  # An error AshPhoenix keeps on the root at a sub-form's path is also copied
  # onto that sub-form, so the same error can be here twice. Each is worded
  # the same either way, and every message below says a sentence once.
  defp raw_errors(form),
    do: form |> AshPhoenix.Form.raw_errors(for_path: :all) |> Map.values() |> List.flatten()

  defp field_path(path, field) do
    path
    |> Enum.reduce("", fn
      index, acc when is_integer(index) -> acc <> "[#{index}]"
      name, "" -> "#{name}"
      name, acc -> acc <> ".#{name}"
    end)
    |> case do
      "" -> field
      prefix -> "#{prefix}.#{field}"
    end
  end

  # The root holds what the action returned; a sub-form refused before the
  # action ran holds its own refusal. No error anywhere explains nothing, so it
  # is not put down to the policy either.
  defp failed_save_message(form) do
    case raw_errors(form) do
      [] ->
        ActionErrors.generic_message()

      errors ->
        errors |> Ash.Error.to_error_class() |> ActionErrors.user_facing_message(form.resource)
    end
  end

  # An error on a field the form renders an input for shows under that input,
  # and only there. Anything else has nowhere on the page to show: an error
  # about the record as a whole (`:_form`, the key `AshPhoenix.FormData.Error`
  # files those under), or one on a field the action sets without offering it
  # (a change, an attribute it does not accept, a read-only field). Those
  # are flashed, worded as `ActionErrors` words a field error, so the submit
  # never fails without saying why. Where an error shows depends on where it
  # belongs, not on how many there are. A sub-form's errors are held to the
  # inputs the page draws for it, and each flashed one says which item it is
  # about: "Items 2 › Note: is hidden".
  defp flash_unplaced_errors(socket, form, scope) do
    form
    |> AshPhoenix.Form.raw_errors(for_path: :all)
    # A map past 32 keys iterates in hash order; the page reads top to bottom.
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {path, errors} ->
      errors
      |> ActionErrors.unplaced_sentences(drawn_inputs(form, path, scope), resource_at(form, path))
      |> Enum.map(&located(&1, form, path))
    end)
    |> Enum.uniq()
    |> case do
      [] -> socket
      sentences -> put_flash(socket, :error, Enum.join(sentences, "\n"))
    end
  end

  defp located(sentence, _form, []), do: sentence
  defp located(sentence, form, path), do: "#{path_label(form, path)} › #{sentence}"

  # Each field is named as the resource of the form holding it labels it.
  # People count items from one.
  defp path_label(form, path), do: form |> path_labels(path) |> Enum.join(" › ")

  defp path_labels(_form, []), do: []

  defp path_labels(form, [field | path]) do
    label = Labels.name(field, form && form.resource)
    sub_forms = form && Map.get(form.forms, field)

    case path do
      [index | path] when is_integer(index) ->
        sub_form = if is_list(sub_forms), do: Enum.at(sub_forms, index)
        ["#{label} #{index + 1}" | path_labels(sub_form, path)]

      path ->
        [label | path_labels(if(is_list(sub_forms), do: nil, else: sub_forms), path)]
    end
  end

  # The resource of the sub-form at `path`, as `drawn_inputs/3` walks it.
  defp resource_at(form, []), do: form.resource

  defp resource_at(form, [field | path]) do
    case {Map.get(form.forms, field), path} do
      {forms, [index | path]} when is_list(forms) ->
        forms |> Enum.at(index) |> then(&(&1 && resource_at(&1, path)))

      {nil, _path} ->
        nil

      {sub_form, path} ->
        resource_at(sub_form, path)
    end
  end

  # The inputs the page draws for the sub-form at `path`, a path as AshPhoenix
  # files errors under: each field is a key of `form.forms`, followed by the
  # item's index when it holds a list. A sub-form under a field this actor
  # cannot see is still built, and can refuse the save, but the page draws none
  # of its inputs.
  defp drawn_inputs(form, [], scope), do: input_names(form, scope)

  defp drawn_inputs(form, [field | path], scope) do
    {sub_form, path} =
      case {Map.fetch!(form.forms, field), path} do
        {forms, [index | path]} when is_list(forms) -> {Enum.at(forms, index), path}
        {sub_form, path} -> {sub_form, path}
      end

    if field in input_names(form, scope),
      do: drawn_inputs(sub_form, path, scope),
      else: MapSet.new()
  end

  # A belongs_to is offered as its relationship, and its errors are filed under
  # the attribute behind it (`owner_id`), which the same input shows.
  defp input_names(form, scope) do
    form
    |> Utils.form_fields(scope)
    |> Enum.flat_map(fn
      %Ash.Resource.Relationships.BelongsTo{} = field -> [field.name, field.source_attribute]
      field -> [field.name]
    end)
    |> MapSet.new()
  end

  defp maybe_put_nested_params(params, form) do
    form.form_keys
    |> Enum.reduce(params, fn {field_name, _}, updated_params ->
      updated_params |> Map.put_new(field_name |> to_string(), %{})
    end)
  end

  # A multi-select emptied of its last pick posts no value under its name, only
  # LiveSelect's `<name>_empty_selection` marker. Read as absent, the field
  # would fall back to the value the record holds, and the select would redraw
  # every stored pick. The marker is the page saying the list is now empty, on
  # the root form and on any sub-form.
  @empty_selection "_empty_selection"

  @doc false
  def put_emptied_selections(%{} = params) when not is_struct(params) do
    Enum.reduce(params, %{}, fn {key, value}, acc ->
      case String.split(key, @empty_selection) do
        [name, ""] when name != "" -> Map.put_new(acc, name, [])
        _other -> Map.put(acc, key, put_emptied_selections(value))
      end
    end)
  end

  def put_emptied_selections(value), do: value

  # A list argument left out of the post means "emptied", so it is put back
  # as `[]`: only for an argument the form handles, never one it leaves out
  # as hidden, which would then save over a value its reader never saw.
  @doc false
  def maybe_put_has_many(params, form) do
    form
    |> Utils.form_fields()
    |> Enum.filter(fn
      %Argument{type: {:array, item_type}} = argument ->
        item_type in [Type.UUID, Type.UUIDv7] or EnumOptions.kind(argument) == :array

      _ ->
        false
    end)
    |> Enum.reduce(params, fn arg, updated_params ->
      updated_params |> Map.put_new(arg.name |> to_string(), [])
    end)
  end

  # A post names attachments by value: a single one rides its hidden input as
  # JSON, an embed's ride its sub-form's, and nothing stops a hand-sent post
  # naming any field at all. The type checks only the visibility prefix, so a
  # key is accepted on its shape — another record's private object included,
  # which the page would then sign a URL for, on the next render as much as
  # after a save. So a post may name only keys this form issued
  # (`assign_issued_attachment_keys/1`).
  #
  # The check reads the validated form rather than the post: what the type's
  # own cast made of it, on the root form and every sub-form, whatever shape
  # carried it there — an attachment, a list, an embed, a union, a typed map, a
  # related record's form under a managed relationship. A field holding a key
  # the form never issued for it goes back to the value the form already held,
  # and the post is validated again. Whether the post named the key is not
  # asked: a cast can decode or normalise a string on its way to the value, so
  # the text of the post is no measure of what it set. An action's change that
  # adds a key of its own during `validate` has it refused the same way; one
  # that wants it should set the value when the form is built.
  #
  # Returns the params to go on with and the form validated with them, or
  # `:refused` when even that holds such a key.
  defp validate_issued(form, params, socket) do
    validated = AshPhoenix.Form.validate(form, params)

    case unissued_fields(validated, socket) do
      [] ->
        {params, validated}

      fields ->
        # Names only: the keys themselves are what was forged.
        Logger.warning(fn ->
          "form post on #{inspect(form.resource)}.#{form.action} named attachment keys " <>
            "the form did not issue, dropped from: #{Enum.join(fields, ", ")}"
        end)

        params = restore_held_params(params, form, fields)
        validated = AshPhoenix.Form.validate(form, params)

        if unissued_fields(validated, socket) == [],
          do: {params, validated},
          else: :refused
    end
  end

  # A key this page minted is taken in the field it was uploaded for, and in no
  # other field the action takes as input: the upload checked the file against
  # that field's types and size, and a post can carry the key anywhere. A
  # field the action does not take can hold a value only because a change put
  # it there — `add_images` folding `:new_images` onto `:images` — from input
  # that was itself checked, so a minted key counts there wherever it was
  # uploaded. That holds only while the input it folds from is an attachment
  # field: a change that builds an attachment from an argument of another type
  # (a string, a map) makes its target trust any key this page minted.
  #
  # The binding is per top-level field, as the issued keys are: a key uploaded
  # for one attachment field of a sub-form can still move to another attachment
  # field under the same top-level field (a row's `:scan` into a row's `:photo`).
  defp unissued_fields(form, socket) do
    issued = Map.get(socket.assigns, :ash_quick_issued_attachment_keys, %{})
    minted = Map.get(socket.assigns, :ash_quick_minted_attachment_keys, %{})
    inputs = action_inputs(form.source)

    for {field, keys} <- attachment_keys_by_field(form, false),
        name = to_string(field),
        allowed =
          minted
          |> Enum.filter(fn {_key, minted_for} ->
            minted_for == name or not input?(inputs, name)
          end)
          |> MapSet.new(&elem(&1, 0))
          |> MapSet.union(Map.get(issued, field, MapSet.new())),
        not MapSet.subset?(keys, allowed),
        do: field
  end

  defp action_inputs(%{action: %{} = action}) do
    accepted = Map.get(action, :accept, []) || []
    arguments = action |> Map.get(:arguments, []) |> Enum.map(& &1.name)
    Enum.map(accepted ++ arguments, &to_string/1)
  end

  # No action to read inputs from: every field is one a post could set.
  defp action_inputs(_source), do: :all

  defp input?(:all, _name), do: true
  defp input?(inputs, name), do: name in inputs

  # Each field goes back to what the form held for it: its last accepted
  # params, or — where it has none yet — nothing, so the record's own value
  # stands. An embed left out of the params would be cleared instead, so it is
  # carried from the changeset the way an upload's fold carries it.
  defp restore_held_params(params, form, fields) do
    keys = Enum.map(fields, &to_string/1)

    params
    |> Map.drop(keys)
    |> Map.merge(Map.take(form.raw_params || %{}, keys))
    |> carry_embedded_params(form)
  end

  # An array of attachments has no scalar rendering, so — unlike a single one,
  # which rides a hidden input — nothing on the page carries its value back.
  # From the moment `upload_progress_handler/4` consumes the picked files, the
  # form's own params are the only record that they belong to this field, and
  # every round trip starting from what the browser posted would drop them: a
  # `validate` would lose them mid-edit, and a save would put the record's old
  # list back over them. Hand them to each round trip instead.
  #
  # For an attribute, the held list is the value, and whatever the browser
  # posted under its name is dropped. No input renders for it, so no honest post
  # contains it, and the visibility prefix is all the type checks: a key taken
  # from the client could be another record's private object, which the details
  # page would then sign a URL for. `[]` is carried like any other list — it is
  # a person removing every file, and leaving it out would put the record's own
  # list back at save.
  #
  # An argument carries only a non-empty batch, and never over what the params
  # already say: a field whose value the action has taken somewhere else (an
  # `add_*` argument folded onto an attribute, say) is dropped from the params
  # as it is folded, and must not be applied a second time here.
  defp carry_uploaded_attachments(params, form) do
    raw_params = form.raw_params || %{}

    Utils.form_fields(form)
    |> Enum.filter(&(&1.type == {:array, AshQuick.AshTypes.Attachment}))
    |> Enum.reduce(params, fn field, updated_params ->
      key = field.name |> to_string()

      case {held_attachments?(field), raw_params} do
        {true, %{^key => held}} -> Map.put(updated_params, key, held)
        {true, _nothing_held} -> Map.delete(updated_params, key)
        {false, %{^key => [_ | _] = held}} -> Map.put_new(updated_params, key, held)
        {false, _nothing_held} -> updated_params
      end
    end)
  end

  # An array *attribute* of attachments is the one shape whose value the form
  # holds on the server. A single attachment rides its hidden input, and an
  # argument is the action's to fold — seeding one from the record would attach
  # every stored file twice.
  defp held_attachments?(%Ash.Resource.Attribute{type: {:array, AshQuick.AshTypes.Attachment}}),
    do: true

  defp held_attachments?(_field), do: false

  defp clearable_attachment_field(form, name) do
    Utils.form_fields(form)
    |> Enum.find(
      &(&1.type == AshQuick.AshTypes.Attachment and &1.allow_nil? and to_string(&1.name) == name)
    )
  end

  defp held_attachments_field(form, name) do
    Utils.form_fields(form)
    |> Enum.find(&(held_attachments?(&1) and to_string(&1.name) == name))
  end

  # What an array attribute of attachments holds right now. Once the form's
  # params have the key, they are the answer, `[]` included. Before that it is
  # the record's own list — which is what makes a first upload on an update form
  # land after the stored files rather than in place of them. A create form has
  # no record, so nothing.
  defp held_attachments(form, field) do
    key = field.name |> to_string()

    case form.raw_params do
      %{^key => held} -> held
      _nothing_held_yet -> stored_attachments(form.data, field.name)
    end
  end

  defp stored_attachments(nil, _field_name), do: nil

  defp stored_attachments(record, field_name) do
    record |> Map.get(field_name) |> List.wrap() |> Enum.map(&attachment_to_params/1)
  end

  # The same shape an upload is consumed into, so the params never hold two
  # kinds of entry.
  defp attachment_to_params(%AshQuick.AshTypes.Attachment.Value{} = value) do
    %{
      "key" => value.key,
      "file_type" => value.file_type && to_string(value.file_type),
      "original_filename" => value.original_filename,
      "byte_size" => value.byte_size
    }
  end

  # A root field's file is consumed as it lands, so the flash saying the store
  # refused it is the only trace the pick leaves: nothing is in the field. It
  # stays up until the person does something about the upload (picks again,
  # cancels an entry, removes a file) rather than going with the next keystroke
  # elsewhere in the form, which would take it down before it is read.
  defp flash_refused_upload(socket, 0), do: clear_refusal(socket)
  defp flash_refused_upload(socket, failed), do: flash_failed_uploads(socket, failed)

  # What an edit to the form does with the flash: takes down whatever the last
  # save or event left, except a refused upload's, which waits on the upload.
  defp clear_form_flash(socket) do
    if refusal_flashed?(socket),
      do: socket |> clear_flash() |> flash_failed_uploads(1),
      else: clear_flash(socket)
  end

  # A pick that lands answers it too, but leaves any other flash alone.
  defp clear_refusal(socket) do
    if refusal_flashed?(socket), do: clear_flash(socket, :error), else: socket
  end

  defp refusal_flashed?(socket),
    do: Phoenix.Flash.get(socket.assigns.flash, :error) == upload_error_message(:not_stored)

  defp flash_failed_uploads(socket, 0), do: socket

  defp flash_failed_uploads(socket, _failed),
    do: put_flash(socket, :error, upload_error_message(:not_stored))

  @doc """
  Names where the browser writes one upload entry: the storage module's
  `c:AshQuick.Storage.upload_target/2`, asked for the write key. Only called
  when the storage module takes uploads externally.

  The key the record will store is the **serving** key, built from the
  field's `:visibility`. Where the bytes actually go is
  `AshQuick.Storage.object_arriving/2`'s call — a host that holds objects somewhere
  first hands back a different key, and the target is asked for that one.
  `upload_images/3` rebuilds the serving key from the same entry when the
  form is submitted, so the record never learns where the bytes waited.

  Both keys go back to the browser: `key` is where to write, `serving_key`
  is the name every surface will render the object under. A client that
  wants to say something about an object it just picked — `attachment_img/1`
  marks its placeholder with the serving key — has it stated rather than
  having to derive it from where the bytes happen to be waiting.

  Custody is taken here, at presign, rather than at submit: `auto_upload:
  true` means the bytes land as soon as a file is picked, so an object the
  host was told about only on save would be one it never heard of for every
  form that is abandoned.

  The serving key is also recorded on the socket as one this page minted,
  for the top-level field the entry's upload is named after
  (`"form[field]_upload"`, or a sub-form's upload under that field). The
  library's own save and progress paths record it again, for the same field,
  when they consume the entry; the record made here is what binds it before
  then (a post that names it ahead of the save) and for a host that consumes
  the entry itself.

  A form takes back only attachment keys it issued, and a minted key counts
  in the field it was uploaded for and in no other field the action takes as
  input, since the upload checked the file against that field's types and
  size. A field the action does not take (one a change folds the upload
  onto) holds it wherever it was uploaded, so a change that builds an
  attachment from an argument that is not an attachment (a string, a map)
  makes that field trust any key the page minted. The binding is per
  top-level field: under a sub-form, a key can still move between attachment
  fields under the same top-level field (a row's scan into a row's photo). A
  host that signs its own uploads without this function, or under an upload
  not named after a form field, has its keys dropped from the post.

  The field's `:accepts` and `:max_size_mb` go with it because they cannot
  be recovered later — a key alone does not say which Ash type constraint
  produced it.

  An entry whose name does not end in one of the field's extensions never
  gets here from a form: the upload's `:validator` refuses it first. Called
  with one anyway, it is refused before any key is opened or signed.

  The target is told the type the name's extension stands for and the
  entry's declared size (`:content_type`, `:content_length`), never the
  browser's declared type. `max_file_size` on `allow_upload/3` only bounds
  what the browser offers at preflight, so a target that does not bind the
  length lets anyone holding it store an object of any size, and one that
  does not bind the type lets them store it as any type.
  """
  def presign_attachment_upload(entry, socket, constraints) do
    case accepted_media_type(entry, constraints) do
      nil -> {:error, %{error: "not_accepted"}, socket}
      media_type -> presign_accepted_upload(entry, socket, constraints, media_type)
    end
  end

  defp presign_accepted_upload(entry, socket, constraints, media_type) do
    serving_key = build_attachment_key(entry, socket, Keyword.fetch!(constraints, :visibility))

    case Storage.object_arriving(
           serving_key,
           arriving_opts(entry, socket, constraints, media_type)
         ) do
      {:ok, write_key} ->
        {:external, uploader, meta} =
          Storage.upload_target(write_key,
            content_type: media_type,
            content_length: entry.client_size
          )

        # Recorded here, where the key is made, rather than where an entry is
        # consumed: a form takes back only keys it issued, and every upload —
        # on the root form or a sub-form, consumed on progress or at save —
        # passes through this one place.
        meta = Map.merge(meta, %{uploader: uploader, key: write_key, serving_key: serving_key})
        {:ok, meta, mint_attachment_key(socket, serving_key, Map.get(entry, :upload_config))}

      # The host refused to take the object. Nothing has been written yet, so
      # failing the entry is the honest outcome — the browser shows the error
      # and the form has no key to save.
      {:error, reason} ->
        Logger.error(
          "upload of #{serving_key} refused by the object lifecycle: #{inspect(reason)}"
        )

        {:error, %{error: "upload_refused"}, socket}
    end
  end

  @doc """
  Renders an upload entry's error for the surface the file was picked on.

  Every error `Phoenix.Component.upload_errors/2` can return has to land
  somewhere: a picker that only knows the built-in atoms crashes the render
  the first time the presigner refuses an entry, which is a live page lost to
  an error the user was supposed to just read.
  """
  def upload_error_message(:too_large), do: gettext("Too large")
  def upload_error_message(:too_many_files), do: gettext("You have selected too many files")

  def upload_error_message(:not_accepted),
    do: gettext("You have selected an unacceptable file type")

  def upload_error_message(:external_client_failure), do: gettext("External Client Failure")

  # The presigner refused the entry, so no URL was signed and no bytes left the
  # browser. Nothing retries it — say the file was not uploaded.
  def upload_error_message({:external_metadata_failure, _meta}),
    do: gettext("This file was refused and has not been uploaded")

  # A socket upload arrived but the store refused it: the file is not saved.
  def upload_error_message(:not_stored),
    do: gettext("This file was refused and has not been uploaded")

  def upload_error_message(error) when is_atom(error), do: Utils.humanize(error)
  def upload_error_message(_error), do: gettext("This file could not be uploaded")

  defp arriving_opts(entry, socket, constraints, media_type) do
    [
      source: :upload_form,
      accepts: Keyword.get(constraints, :accepts),
      max_bytes: attachment_max_bytes(constraints),
      content_type: media_type,
      byte_size: entry.client_size,
      filename: entry.client_name,
      resource: socket.assigns.resource,
      # A create form has no record yet, which is why the link to what an
      # object belongs to is stamped at save instead.
      resource_id: socket.assigns |> Map.get(:record) |> record_id(),
      scope: Map.get(socket.assigns, :scope)
    ]
  end

  defp record_id(%{id: id}), do: id
  defp record_id(_record), do: nil

  defp build_attachment_key(entry, socket, visibility) do
    directory = Ash.Resource.Info.plural_name(socket.assigns.resource)
    "#{visibility}/#{directory}/#{entry.uuid}-#{safe_filename(entry.client_name)}"
  end

  @doc """
  Slugifies a browser-supplied filename into a storage-key-safe segment.

  The human-readable filename in a key is cosmetic — a UUID guarantees
  uniqueness and `original_filename` preserves the real name for display.
  Slugifying keeps URL-unsafe characters (spaces, parens, `#`, unicode, ...)
  out of the storage key, and therefore out of the URL. Both the base name
  and the extension are slugged — the extension keeps only `[a-z0-9]` so
  something like `report.jp g` or `x.htm<b>l` can't smuggle spaces, control
  bytes, or markup into the key.

  Crucially it is also the traversal guard: `Path.basename/2` strips any
  directory components and the `[^a-z0-9]+` collapse destroys `.` and `/`,
  so a `client_name` like `../../public/evil.html` can never escape its
  intended prefix. Every presigned-upload key builder that interpolates a
  browser-controlled name MUST route it through this function.
  """
  def safe_filename(name) when is_binary(name) do
    ext = name |> Path.extname() |> slug_extension()

    base =
      name
      |> Path.basename(Path.extname(name))
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    case base do
      "" -> "file" <> ext
      base -> base <> ext
    end
  end

  def safe_filename(_), do: "file"

  # Slugs a `.ext` down to its leading dot plus `[a-z0-9]` only, dropping the
  # extension entirely when nothing survives (so `x/..` -> "file", not "file.").
  defp slug_extension("." <> rest) do
    case rest |> String.downcase() |> String.replace(~r/[^a-z0-9]+/u, "") do
      "" -> ""
      cleaned -> "." <> cleaned
    end
  end

  defp slug_extension(_), do: ""

  defp infer_attachment_file_type(filename) when is_binary(filename) do
    ext = filename |> safe_filename() |> Path.extname()

    Enum.find_value(@attachment_media_types, fn {class, types} ->
      if List.keymember?(types, ext, 0), do: class
    end)
  end

  defp infer_attachment_file_type(_), do: nil

  # The sub-forms of a list, against the params the browser posted for them.
  # Those are keyed by position — `form[images][0]`, `[1]`, ... — which is what
  # pairs a sub-form with its params here. `_persistent_id` is the wrong handle
  # for it: it is deliberately stable across a removal, exactly so a `validate`
  # can match params to the form they came from, so once a sub-form is removed
  # the ids left behind no longer count from zero while the re-rendered inputs
  # do. Keying by it paired every later sub-form with the params of the one
  # before it, and looked up a key past the end of the post — which took the
  # LiveView down rather than failing the save.
  #
  # A position the post says nothing about is left alone: there is no sub-form
  # params map to fold an upload into, and inventing one would submit a blank
  # entry the seller never filled in.
  #
  # Every clause returns the params with what the save made of its entries: how
  # many the store refused, and the keys it stored the rest under.
  @no_uploads {0, []}

  defp upload_images(params, socket, forms) when is_list(forms) and is_map(params) do
    forms
    |> Enum.with_index()
    |> Enum.reduce({params, @no_uploads}, fn {form, position}, {updated_params, tally} ->
      key = position |> to_string()

      case updated_params do
        %{^key => posted} when is_map(posted) ->
          {nested, nested_tally} = upload_images(posted, socket, form)
          {Map.put(updated_params, key, nested), add_tally(tally, nested_tally)}

        _nothing_to_fold_into ->
          {updated_params, tally}
      end
    end)
  end

  # A list carried from the changeset (`carry_embedded_params/2`) rather than
  # posted by the browser: the same entries, by position.
  defp upload_images(params, socket, forms) when is_list(forms) and is_list(params) do
    params
    |> Enum.with_index()
    |> Map.new(fn {posted, position} -> {to_string(position), posted} end)
    |> upload_images(socket, forms)
  end

  defp upload_images(params, socket, form) when is_map(params) do
    Utils.form_fields(form)
    |> Enum.reduce({params, @no_uploads}, fn field, {updated_params, tally} ->
      {updated_params, field_tally} = maybe_upload_image(field, updated_params, socket, form)
      {updated_params, add_tally(tally, field_tally)}
    end)
  end

  defp add_tally({refused, keys}, {more_refused, more_keys}),
    do: {refused + more_refused, more_keys ++ keys}

  defp maybe_upload_image(%{type: field_type} = field, params, socket, form)
       when field_type in [
              AshQuick.AshTypes.Attachment,
              {:array, AshQuick.AshTypes.Attachment}
            ] do
    constraints = attachment_constraints(field)
    upload_name = upload_name(socket.assigns, form, field)
    params = drop_blank_attachment_param(params, field)

    {uploaded_values, refused} = consume_attachment_entries(socket, upload_name, constraints)

    params =
      case {field.type, uploaded_values, form.data} do
        {_, [], nil} ->
          params

        {_, [], data} ->
          params
          |> Map.put_new(field.name |> to_string(), kept_attachment(field, data, socket, form))

        {AshQuick.AshTypes.Attachment, [value], _} ->
          params |> Map.put(field.name |> to_string(), value)

        {{:array, AshQuick.AshTypes.Attachment}, values, _} ->
          params
          |> Map.put(field.name |> to_string(), saved_before(field, params, form) ++ values)
      end

    {params, {refused, Enum.map(uploaded_values, &{&1["key"], upload_name})}}
  end

  defp maybe_upload_image(%{name: field_name}, params, socket, form)
       when is_map_key(form.forms, field_name) do
    nested_form = form.forms[field_name]

    {nested_params, tally} =
      Map.get(params, field_name |> to_string())
      |> upload_images(socket, nested_form)

    {Map.put(params, field_name |> to_string(), nested_params), tally}
  end

  defp maybe_upload_image(_field, params, _socket, _form), do: {params, @no_uploads}

  # What a save's unconsumed entries land after. For an array attribute that is
  # the list the params hold — carried from the server by
  # `carry_uploaded_attachments/2` — or, where they hold none, the record's. An
  # argument starts from nothing, as it always has.
  defp saved_before(field, params, form) do
    key = field.name |> to_string()

    case {held_attachments?(field), params} do
      {true, %{^key => held}} when is_list(held) -> held
      {true, _nothing_held} -> stored_attachments(form.data, field.name) || []
      {false, _argument} -> []
    end
  end

  # The attachment params for every entry the upload took, in the order the
  # files were picked in, which is the order the images are stored in: the
  # first of them is the featured one.
  #
  # An entry the upload refused (its `:validator`, or a presign that failed)
  # never finishes, so it is passed over rather than consumed: left in place,
  # it keeps its error on the page until it is picked again or removed, and
  # `consume_uploaded_entry/3` would raise on it as one still in progress.
  #
  # Returns the params with how many entries could not be stored. Only a socket
  # upload can fail here: an external one is in the store already.
  defp consume_attachment_entries(socket, upload_name, constraints) do
    socket
    |> valid_entries(upload_name)
    |> Enum.map(fn entry ->
      consume_uploaded_entry(
        socket,
        entry,
        &consume_attachment_entry(&1, entry, socket, constraints)
      )
    end)
    |> Enum.split_with(&(&1 != :not_stored))
    |> then(fn {values, failed} -> {values, length(failed)} end)
  end

  defp consume_attachment_entry(meta, entry, socket, constraints) do
    key = build_attachment_key(entry, socket, Keyword.fetch!(constraints, :visibility))

    case store_socket_upload(meta, key, entry, socket, constraints) do
      :ok -> {:ok, attachment_params(key, entry)}
      :error -> {:ok, :not_stored}
    end
  end

  # A presign that failed leaves its entry `valid?`, but with an upload error.
  defp valid_entries(socket, upload_name) do
    conf = socket.assigns.uploads[upload_name]

    Enum.filter(conf.entries, &(&1.valid? and Phoenix.Component.upload_errors(conf, &1) == []))
  end

  defp attachment_params(key, entry) do
    file_type = infer_attachment_file_type(entry.client_name)

    %{
      "key" => key,
      "file_type" => file_type && to_string(file_type),
      "original_filename" => entry.client_name,
      "byte_size" => entry.client_size
    }
  end

  # An external upload's bytes are already stored. Its meta is told apart by
  # the `:uploader` AshQuick always puts on it (`presign_attachment_upload/3`),
  # not by what the host's own meta holds: a host may well name a `path` there.
  defp store_socket_upload(%{uploader: _external}, _serving_key, _entry, _socket, _constraints),
    do: :ok

  # A socket upload is a temporary file on this server, gone once the entry is
  # consumed, so it is stored now: the host is told it is arriving (the custody
  # an external upload takes at presign) and the bytes go to the key it names.
  # `put_file/3` runs in the LiveView process, so the page waits on the store.
  defp store_socket_upload(%{path: path}, serving_key, entry, socket, constraints) do
    # The upload's `:validator` let the entry through, so its name is one the
    # field accepts.
    media_type = accepted_media_type(entry, constraints)

    with {:ok, write_key} <-
           Storage.object_arriving(
             serving_key,
             arriving_opts(entry, socket, constraints, media_type)
           ),
         :ok <- Storage.put_file(write_key, path, content_type: media_type) do
      :ok
    else
      {:error, reason} ->
        Logger.error("upload of #{serving_key} was not stored: #{inspect(reason)}")
        :error
    end
  end

  # A blank single attachment on an update keeps the record's own, unless its ✕
  # emptied it on this form: the hidden input posts blank either way, so the ✕
  # is remembered here.
  defp kept_attachment(field, data, socket, form) do
    cleared = Map.get(socket.assigns, :ash_quick_cleared_attachments, MapSet.new())

    if field.type == AshQuick.AshTypes.Attachment and not String.contains?(form.name, "[") and
         MapSet.member?(cleared, field.name),
       do: nil,
       else: Map.get(data, field.name)
  end

  # The field's hidden input posts an empty string when it is carrying nothing —
  # which no attachment type can cast. Dropping the key lets the branches below
  # decide the value: the record's own attachment, or nothing at all.
  defp drop_blank_attachment_param(params, field) do
    key = field.name |> to_string()

    case Map.get(params, key) do
      blank when blank in [nil, ""] -> Map.delete(params, key)
      _present -> params
    end
  end

  # Which objects the save just attached, read off the saved record rather than
  # the submitted params: the record holding the key inside its attachment value
  # is the authoritative direction, and it covers the keys that were already
  # there as well as the ones this submit uploaded.
  # Inside the save rather than after it, so a host that cannot take on the
  # objects takes the record down with it. A saved record pointing at an object
  # its host never accepted is one the page can never resolve, and the seller
  # would have been told the save worked.
  # The scope goes with it, so the host records the reference as whoever saved.
  defp reference_attachments(%Ash.Changeset{} = changeset, scope) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      record
      |> attachment_keys()
      |> Storage.object_referenced(record.__struct__, Map.get(record, :id), scope: scope)
      |> case do
        :ok -> {:ok, record}
        {:error, error} -> {:error, error}
      end
    end)
  end

  # A read form or a generic action carries no attachments to reference.
  defp reference_attachments(source, _scope), do: source

  defp attachment_keys(record), do: Storage.attachment_keys(record)

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
