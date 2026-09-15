defmodule AshQuick.LiveView.FormUtils do
  @moduledoc false
  require Ash.Query
  require Logger
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 2]
  alias AshQuick.LiveView.ActionErrors
  alias AshQuick.LiveView.URLParams
  alias AshQuick.LiveView.QuickView.Options
  alias Ash.Resource.Actions.Argument
  alias Ash.Type
  alias AshQuick.LiveView.Utils
  alias AshQuick.Storage

  def do_handle_params(
        socket,
        %URLParams{} = params,
        %{type: action_type, name: action_name} = _action,
        %Options{} = options
      )
      when action_type in [:create, :update] do
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
  end

  defp set_title(socket, action_name, %{resource: resource}) do
    resource_name = Ash.Resource.Info.short_name(resource)
    title = "[#{resource_name |> Utils.humanize()}] #{action_name |> Utils.humanize()} "
    socket |> assign(page_title: title)
  end

  defp set_record!(socket, :create, _action_name, _params, _options), do: socket

  defp set_record!(socket, :update, action_name, %URLParams{id: id}, options) do
    # A relationship is named whole rather than by a field of it: a dropdown
    # seeds its currently-selected option from this record rather than from its
    # own query, and `load_fields/3` brings the destination's display label
    # along with the relationship — otherwise the one option the user is
    # actually looking at is the one rendered as a UUID.
    fields =
      Utils.action_fields(options.resource, action_name)
      |> Enum.map(&Utils.argument_to_relationship(&1, options.resource))
      |> Enum.map(fn
        %Ash.Resource.Attribute{name: name} -> name
        %Ash.Resource.Relationships.BelongsTo{name: name} -> name
        %Ash.Resource.Relationships.ManyToMany{name: name} -> name
        _ -> []
      end)

    record =
      options.resource
      |> Ash.Query.for_read(:read, %{}, scope: socket.assigns.scope)
      |> Ash.Query.filter(id == ^id)
      |> Ash.Query.load(options.load, strict?: true)
      |> Utils.load_fields(fields, strict?: true)
      |> Ash.read_one!()

    socket |> assign(record: record)
  end

  defp set_form(socket, :create, _options) do
    form =
      AshPhoenix.Form.for_create(socket.assigns.resource, socket.assigns.ash_action.name,
        transform_params: &transform_nested_params/3,
        scope: socket.assigns.scope,
        actor: actor(socket)
      )
      |> then(&add_nested_forms(&1, &1.form_keys))

    socket |> assign(form: form)
  end

  # The read in `set_record!/5` runs through the actor's scope, so a record the
  # actor may not read comes back as nil — indistinguishable from one that does
  # not exist. There is no form to build for it: leave `form: nil` and let
  # `FormView.form_view/1` render the forbidden panel.
  defp set_form(%{assigns: %{record: nil}} = socket, :update, _options) do
    socket |> assign(form: nil)
  end

  defp set_form(socket, :update, _options) do
    form =
      AshPhoenix.Form.for_update(socket.assigns.record, socket.assigns.ash_action.name,
        transform_params: &transform_nested_params/3,
        scope: socket.assigns.scope,
        actor: actor(socket)
      )
      |> then(&add_nested_forms(&1, &1.form_keys))
      |> prefill_form_has_many_args(socket)
      |> prefill_changed_embedded_forms()

    socket |> assign(form: form)
  end

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

  defp prefill_form_has_many_arg(form, resource, %Argument{type: {:array, item_type}} = arg)
       when item_type in [Type.UUID, Type.UUIDv7] do
    relation_name = String.trim_trailing(arg.name |> to_string(), "_ids")

    relationship =
      Ash.Resource.Info.relationship(resource, relation_name)

    if relationship && is_list(form.data |> Map.get(relationship.name)) do
      value = form.data |> Map.get(relationship.name) |> Enum.map(& &1.id)
      form |> AshPhoenix.Form.update_params(&Map.put(&1, arg.name, value))
    else
      form
    end
  end

  defp prefill_form_has_many_arg(form, _resource, _arg), do: form

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

  defp allow_image_upload(socket, forms, root? \\ true)

  defp allow_image_upload(socket, forms, root?) when is_list(forms) do
    Enum.reduce(forms, socket, &allow_image_upload(&2, &1, root?))
  end

  defp allow_image_upload(socket, form, root?) do
    Utils.action_fields(form.resource, form.action)
    |> Enum.reduce(socket, &maybe_allow_upload(form, &1, &2, root?))
    |> then(
      &Enum.reduce(form.forms |> Map.values(), &1, fn nested_form, socket_acc ->
        allow_image_upload(socket_acc, nested_form, false)
      end)
    )
  end

  defp maybe_allow_upload(form, field, socket, root?)
       when field.type in [
              AshQuick.AshTypes.Attachment,
              {:array, AshQuick.AshTypes.Attachment}
            ] do
    upload_name = "#{form.name}[#{field.name}]_upload"

    case socket.assigns[:uploads][upload_name] do
      nil ->
        constraints = attachment_constraints(field)
        accepts = Keyword.fetch!(constraints, :accepts)

        allow_upload(socket, upload_name,
          accept: attachment_accept_extensions(accepts),
          max_entries: if(field.type == AshQuick.AshTypes.Attachment, do: 1, else: 10),
          max_file_size: attachment_max_bytes(constraints),
          external: fn entry, socket ->
            presign_attachment_upload(entry, socket, constraints)
          end,
          auto_upload: true,
          progress: upload_progress_handler(upload_name, field, constraints, root?)
        )

      _ ->
        socket
    end
  end

  defp maybe_allow_upload(_form, _field, socket, _root?), do: socket

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
    entries = socket.assigns.uploads[upload_name].entries

    if entries != [] and Enum.all?(entries, & &1.done?) do
      values = consume_attachment_entries(socket, upload_name, constraints)
      put_uploaded_values(socket, field, values)
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
    key = field.name |> to_string()
    raw_params = form.raw_params || %{}
    value = fold_uploaded_values(field, raw_params[key], values)

    # The field's own params are folded into `value` above, so they must not
    # survive into the re-seed as well — they would be applied a second time.
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

  defp attachment_accept_extensions(accepts) do
    accepts
    |> Enum.flat_map(fn
      :image -> ~w(.jpg .jpeg .png .webp)
      :video -> ~w(.mp4 .mov .webm)
    end)
  end

  # No form was built because the record is not readable by this actor, so the
  # page is showing the forbidden panel. Nothing stops someone pushing a form
  # event at it anyway — refuse rather than build on a nil form.
  defp handle_form_events(event, _params, %{assigns: %{form: nil}} = socket, _options)
       when event in ["cancel-upload", "add-form", "remove-form", "validate", "save"] do
    {:halt, socket |> put_flash(:error, AshQuick.LiveView.ActionErrors.forbidden_message())}
  end

  defp handle_form_events("cancel-upload", params, socket, _options) do
    {:halt, socket |> cancel_upload(params["entry"], params["ref"]) |> clear_flash()}
  end

  defp handle_form_events("add-form", %{"path" => path}, socket, _options) do
    form = AshPhoenix.Form.add_form(socket.assigns.form, path)
    {:halt, socket |> assign(form: form) |> allow_image_upload(form) |> clear_flash()}
  end

  defp handle_form_events("remove-form", %{"path" => path}, socket, _options) do
    form = AshPhoenix.Form.remove_form(socket.assigns.form, path)
    {:halt, socket |> assign(form: form) |> clear_flash()}
  end

  defp handle_form_events("validate", %{"form" => params}, socket, _options) do
    params =
      params
      |> carry_uploaded_attachments(socket.assigns.form)
      |> maybe_put_has_many(socket.assigns.form)

    form = AshPhoenix.Form.validate(socket.assigns.form, params)

    {:halt, socket |> assign(form: form) |> clear_flash()}
  end

  defp handle_form_events("save", %{"form" => params}, socket, _options) do
    params = carry_uploaded_attachments(params, socket.assigns.form)
    form = AshPhoenix.Form.validate(socket.assigns.form, params)

    case AshPhoenix.Form.submit(form,
           params:
             params
             |> maybe_put_nested_params(form)
             |> maybe_put_has_many(form)
             |> upload_images(socket, form),
           before_submit: &reference_attachments/1,
           action_opts: [context: %{action_source: AshQuick.form_source()}]
         ) do
      {:ok, rec} ->
        handle_success(rec, params, socket.assigns.ash_action.name, socket)

      # Every message below comes from `AshQuick.LiveView.ActionErrors`, which
      # owns what a failed action says to a person. Spelling one out here is how
      # the same condition ends up worded two ways depending on which surface
      # hit it — and how `Ash.Error.error_descriptions/1`, a debug dump of the
      # error class and its bread crumbs, ends up in a toast.
      {:error, %{source: %{errors: [%Ash.Error.Changes.StaleRecord{} = error]}}} ->
        Logger.warning("Stale record error: #{inspect(error)}")

        {:halt, put_flash(socket, :error, ActionErrors.user_facing_message(error))}

      {:error, %{source: %{errors: [%Ash.Error.Changes.InvalidAttribute{} = error]}} = form} ->
        Logger.warning("Invalid attribute error: #{inspect(error)}")

        # Wrapped in the class Ash would have raised it under, which is the
        # shape `user_facing_message/1` renders sub-errors out of.
        message = ActionErrors.user_facing_message(Ash.Error.to_error_class([error]))

        {:halt, socket |> assign(form: form) |> put_flash(:error, message)}

      {:error, form} ->
        Logger.warning("Error while saving form: \n #{form |> inspect()}")

        case AshPhoenix.Form.errors(form) do
          # A submit that failed with nothing to say about any input is the
          # policy refusing it.
          [] -> {:halt, put_flash(socket, :error, ActionErrors.forbidden_message())}
          errors -> {:halt, socket |> assign(form: form) |> flash_form_errors(errors)}
        end
    end
  end

  defp handle_form_events(_, _, socket, _options), do: {:cont, socket}

  # An error about the record as a whole names no input — `:_form` is the key
  # `AshPhoenix.FormData.Error` files those under — so there is no field beside
  # which it would render. Flashed instead: without this the submit fails and
  # the page says nothing at all about why.
  defp flash_form_errors(socket, errors) do
    errors
    |> Enum.flat_map(fn
      {:_form, message} when is_binary(message) -> [message]
      _named_input -> []
    end)
    |> case do
      [] -> socket
      messages -> put_flash(socket, :error, Enum.join(messages, "\n"))
    end
  end

  defp maybe_put_nested_params(params, form) do
    form.form_keys
    |> Enum.reduce(params, fn {field_name, _}, updated_params ->
      updated_params |> Map.put_new(field_name |> to_string(), %{})
    end)
  end

  defp maybe_put_has_many(params, form) do
    AshPhoenix.Form.arguments(form)
    |> Enum.filter(fn
      %Argument{type: {:array, item_type}} ->
        item_type in [Type.UUID, Type.UUIDv7, Type.Atom] and
          true

      _ ->
        false
    end)
    |> Enum.reduce(params, fn arg, updated_params ->
      updated_params |> Map.put_new(arg.name |> to_string(), [])
    end)
  end

  # An array of attachments has no scalar rendering, so — unlike a single one,
  # which rides a hidden input — nothing on the page carries its value back.
  # From the moment `upload_progress_handler/4` consumes the picked files, the
  # form's own params are the only record that they belong to this field, and
  # every round trip starting from what the browser posted would drop them: a
  # `validate` would lose them mid-edit, and a save would put the record's old
  # list back over them. Hand them to each round trip instead.
  #
  # Only what the params do not already speak for: a field whose value the
  # action has taken somewhere else (an `add_*` argument folded onto an
  # attribute, say) is dropped from the params as it is folded, and must not be
  # applied a second time here.
  defp carry_uploaded_attachments(params, form) do
    Utils.action_fields(form.resource, form.action)
    |> Enum.filter(&(&1.type == {:array, AshQuick.AshTypes.Attachment}))
    |> Enum.reduce(params, fn field, updated_params ->
      key = field.name |> to_string()

      case Map.get(form.raw_params || %{}, key) do
        [_ | _] = held -> Map.put_new(updated_params, key, held)
        _nothing_held -> updated_params
      end
    end)
  end

  @doc """
  Signs the browser's `PUT` for one upload entry.

  The key the record will store is the **serving** key, built from the
  field's `:visibility`. Where the bytes actually go is
  `AshQuick.Storage.object_arriving/2`'s call — a host that holds objects somewhere
  first hands back a different key, and the URL is signed for that one.
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

  The field's `:accepts` and `:max_size_mb` go with it because they cannot
  be recovered later — a key alone does not say which Ash type constraint
  produced it.

  `Content-Length` is pinned to the entry's declared size: `max_file_size`
  on `allow_upload/3` only bounds what the browser offers at preflight, so
  without a signed length anyone holding the URL can store an object of any
  size. It is signed as a *header* rather than a query parameter — that is
  what puts it in the canonical request and makes a differently-sized body
  fail signature validation.
  """
  def presign_attachment_upload(entry, socket, constraints) do
    serving_key = build_attachment_key(entry, socket, Keyword.fetch!(constraints, :visibility))

    case Storage.object_arriving(serving_key, arriving_opts(entry, socket, constraints)) do
      {:ok, write_key} ->
        url =
          Storage.presigned_put_url(write_key,
            content_type: entry.client_type,
            content_length: entry.client_size
          )

        {:ok, %{uploader: "S3", key: write_key, serving_key: serving_key, url: url}, socket}

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
  def upload_error_message(:too_large), do: "Too large"
  def upload_error_message(:too_many_files), do: "You have selected too many files"
  def upload_error_message(:not_accepted), do: "You have selected an unacceptable file type"
  def upload_error_message(:external_client_failure), do: "External Client Failure"

  # The presigner refused the entry, so no URL was signed and no bytes left the
  # browser. Nothing retries it — say the file was not uploaded.
  def upload_error_message({:external_metadata_failure, _meta}),
    do: "This file was refused and has not been uploaded"

  def upload_error_message(error) when is_atom(error), do: Utils.humanize(error)
  def upload_error_message(_error), do: "This file could not be uploaded"

  defp arriving_opts(entry, socket, constraints) do
    [
      source: :upload_form,
      accepts: Keyword.get(constraints, :accepts),
      max_bytes: attachment_max_bytes(constraints),
      content_type: entry.client_type,
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
    case filename |> Path.extname() |> String.downcase() do
      ext when ext in ~w(.jpg .jpeg .png .heic .webp) -> :image
      ext when ext in ~w(.mp4 .mov .webm .mkv) -> :video
      _ -> nil
    end
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
  defp upload_images(params, socket, forms) when is_list(forms) and is_map(params) do
    forms
    |> Enum.with_index()
    |> Enum.reduce(params, fn {form, position}, updated_params ->
      key = position |> to_string()

      case updated_params do
        %{^key => posted} when is_map(posted) ->
          updated_params |> Map.put(key, upload_images(posted, socket, form))

        _nothing_to_fold_into ->
          updated_params
      end
    end)
  end

  defp upload_images(params, socket, form) when is_map(params) do
    Utils.action_fields(form.resource, form.action)
    |> Enum.reduce(params, fn field, updated_params ->
      maybe_upload_image(field, updated_params, socket, form)
    end)
  end

  defp maybe_upload_image(%{type: field_type} = field, params, socket, form)
       when field_type in [
              AshQuick.AshTypes.Attachment,
              {:array, AshQuick.AshTypes.Attachment}
            ] do
    constraints = attachment_constraints(field)
    upload_name = "#{form.name}[#{field.name}]_upload"
    params = drop_blank_attachment_param(params, field)

    uploaded_values = consume_attachment_entries(socket, upload_name, constraints)

    case {field.type, uploaded_values, form.data} do
      {_, [], nil} ->
        params

      {_, [], data} ->
        params |> Map.put_new(field.name |> to_string(), Map.get(data, field.name))

      {AshQuick.AshTypes.Attachment, [value], _} ->
        params |> Map.put(field.name |> to_string(), value)

      {{:array, AshQuick.AshTypes.Attachment}, values, _} ->
        params |> Map.put(field.name |> to_string(), values)
    end
  end

  defp maybe_upload_image(%{name: field_name}, params, socket, form)
       when is_map_key(form.forms, field_name) do
    nested_form = form.forms[field_name]

    nested_params =
      Map.get(params, field_name |> to_string())
      |> upload_images(socket, nested_form)

    params |> Map.put(field_name |> to_string(), nested_params)
  end

  defp maybe_upload_image(_field, params, _socket, _form), do: params

  # The attachment params for every finished entry, in the order the files were
  # picked in: `Phoenix.LiveView.Upload.uploaded_entries/2` builds its done-list
  # by prepending, and every entry is done by the time consuming is allowed — so
  # what comes back is the selection order backwards. That order is the order
  # the images are stored in, and the first of them is the featured one.
  defp consume_attachment_entries(socket, upload_name, constraints) do
    visibility = Keyword.fetch!(constraints, :visibility)

    socket
    |> consume_uploaded_entries(upload_name, fn _meta, entry ->
      key = build_attachment_key(entry, socket, visibility)
      file_type = infer_attachment_file_type(entry.client_name)

      {:ok,
       %{
         "key" => key,
         "file_type" => file_type && to_string(file_type),
         "original_filename" => entry.client_name,
         "byte_size" => entry.client_size
       }}
    end)
    |> Enum.reverse()
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
  defp reference_attachments(%Ash.Changeset{} = changeset) do
    Ash.Changeset.after_action(changeset, fn _changeset, record ->
      record
      |> attachment_keys()
      |> Storage.object_referenced(record.__struct__, Map.get(record, :id))
      |> case do
        :ok -> {:ok, record}
        {:error, error} -> {:error, error}
      end
    end)
  end

  # A read form or a generic action carries no attachments to reference.
  defp reference_attachments(source), do: source

  defp attachment_keys(record), do: Storage.attachment_keys(record)

  defp handle_success(record, _form_params, _action, socket) do
    %{base_path: base_path, params: params} = socket.assigns

    details_params = params |> URLParams.to_details_params(record.id)
    details_path = URLParams.full_path(base_path, details_params)

    {:halt,
     socket
     |> put_flash(:info, "Record saved successfully")
     |> push_patch(to: details_path)}
  end
end
