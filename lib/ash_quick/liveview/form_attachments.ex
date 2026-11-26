defmodule AshQuick.LiveView.FormAttachments do
  @moduledoc false
  # The attachment values a form holds: what an upload adds, what a ✕ removes,
  # what each round trip carries, the entries a save consumes and stores, and
  # the objects a saved record references.
  require Logger

  import Phoenix.LiveView,
    only: [put_flash: 3, clear_flash: 1, clear_flash: 2, consume_uploaded_entry: 3]

  import Phoenix.Component, only: [assign: 2]
  alias Ash.Resource.Actions.Argument
  alias AshQuick.LiveView.AttachmentKeys
  alias AshQuick.LiveView.SubForms
  alias AshQuick.LiveView.AttachmentUpload
  alias AshQuick.LiveView.FormParams
  alias AshQuick.LiveView.FormStateFlow
  alias AshQuick.LiveView.FormUploads
  alias AshQuick.LiveView.Utils
  alias AshQuick.Storage

  @doc false
  def consume_completed_upload(socket, upload_name, field, constraints) do
    entries = valid_entries(socket, upload_name)

    if entries != [] and Enum.all?(entries, & &1.done?) do
      {values, failed} = consume_attachment_entries(socket, upload_name, constraints)

      # A socket upload's key is made here rather than at presign, so this is
      # where the form learns it issued it.
      values
      |> Enum.reduce(socket, &AttachmentKeys.mint_attachment_key(&2, &1["key"], upload_name))
      |> put_uploaded_values(field, values)
      |> flash_refused_upload(failed)
    else
      socket
    end
  end

  defp put_uploaded_values(socket, _field, []), do: socket

  defp put_uploaded_values(socket, field, values) do
    form = socket.assigns.form
    held = if held_attachments?(field), do: held_attachments(form, field)

    put_field_value(socket, field, fold_uploaded_values(field, held, values))
  end

  # Validates the form with `value` as the field's params and everything else
  # it already holds.
  @doc false
  def put_field_value(socket, field, value) do
    form = socket.assigns.form
    key = field.name |> to_string()
    raw_params = form.raw_params || %{}

    # The field's own params are folded into `value` by the caller, so what
    # it held before is dropped, not applied a second time.
    carried = raw_params |> Map.delete(key) |> FormParams.carry_embedded_params(form)

    params = Map.put(carried, key, value)

    # A field the form's state hides takes nothing from here either.
    {settled, validated, _state} =
      FormStateFlow.settle(SubForms.validate(form, params), :validate, socket)

    form = FormParams.prefill_changed_embedded_forms(validated, reseed_params(settled, field))

    # Folding the values in can create sub-forms — an embedded array grows a
    # form per image — and each one's own attachment field needs its upload
    # registered before a save goes looking for it.
    socket
    |> assign(form: form)
    |> FormStateFlow.store(:validate)
    |> FormUploads.allow_image_upload(form)
  end

  # The params the embeds' re-seed validates with, which the changeset's
  # value for each embed overrides. An attribute keeps its value just put:
  # left out, the re-seed would drop it (an attachment beside an embed drawn
  # as sub-forms). An argument does not: a change that folds it onto an
  # embed has already, so the embed's seeded value holds it, and the
  # argument once more would fold it a second time.
  defp reseed_params(params, %Argument{name: name}), do: Map.delete(params, to_string(name))
  defp reseed_params(params, _attribute), do: params

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
  @doc false
  def carry_uploaded_attachments(params, form) do
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
  @doc false
  def held_attachments?(%Ash.Resource.Attribute{type: {:array, AshQuick.AshTypes.Attachment}}),
    do: true

  def held_attachments?(_field), do: false

  @doc false
  def clearable_attachment_field(form, name) do
    Utils.form_fields(form)
    |> Enum.find(
      &(&1.type == AshQuick.AshTypes.Attachment and &1.allow_nil? and to_string(&1.name) == name)
    )
  end

  @doc false
  def held_attachments_field(form, name) do
    Utils.form_fields(form)
    |> Enum.find(&(held_attachments?(&1) and to_string(&1.name) == name))
  end

  # What an array attribute of attachments holds right now. Once the form's
  # params have the key, they are the answer, `[]` included. Before that it is
  # the record's own list — which is what makes a first upload on an update form
  # land after the stored files rather than in place of them. A create form has
  # no record, so nothing.
  def held_attachments(form, field) do
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
  @doc false
  def clear_form_flash(socket) do
    if refusal_flashed?(socket),
      do: socket |> clear_flash() |> flash_failed_uploads(1),
      else: clear_flash(socket)
  end

  # A pick that lands answers it too, but leaves any other flash alone.
  defp clear_refusal(socket) do
    if refusal_flashed?(socket), do: clear_flash(socket, :error), else: socket
  end

  defp refusal_flashed?(socket),
    do:
      Phoenix.Flash.get(socket.assigns.flash, :error) ==
        AttachmentUpload.upload_error_message(:not_stored)

  @doc false
  def flash_failed_uploads(socket, 0), do: socket

  def flash_failed_uploads(socket, _failed),
    do: put_flash(socket, :error, AttachmentUpload.upload_error_message(:not_stored))

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

  @doc false
  def upload_images(params, socket, forms) when is_list(forms) and is_map(params) do
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
  def upload_images(params, socket, forms) when is_list(forms) and is_list(params) do
    params
    |> Enum.with_index()
    |> Map.new(fn {posted, position} -> {to_string(position), posted} end)
    |> upload_images(socket, forms)
  end

  def upload_images(params, socket, form) when is_map(params) do
    Utils.form_fields(form)
    |> Enum.reduce({params, @no_uploads}, fn field, {updated_params, tally} ->
      {updated_params, field_tally} = maybe_upload_image(field, updated_params, socket, form)
      {updated_params, add_tally(tally, field_tally)}
    end)
  end

  # Not a row's params, as a single sub-form posted as text is not.
  def upload_images(params, _socket, _form), do: {params, @no_uploads}

  defp add_tally({refused, keys}, {more_refused, more_keys}),
    do: {refused + more_refused, more_keys ++ keys}

  defp maybe_upload_image(%{type: field_type} = field, params, socket, form)
       when field_type in [
              AshQuick.AshTypes.Attachment,
              {:array, AshQuick.AshTypes.Attachment}
            ] do
    if FormStateFlow.takes_upload?(socket, form, field),
      do: upload_image(field, params, socket, form),
      else: {params, @no_uploads}
  end

  defp maybe_upload_image(%{name: field_name} = field, params, socket, form)
       when is_map_key(form.forms, field_name) do
    if FormStateFlow.takes_upload?(socket, form, field),
      do: upload_nested_images(field_name, params, socket, form),
      else: {params, @no_uploads}
  end

  defp maybe_upload_image(_field, params, _socket, _form), do: {params, @no_uploads}

  # A sub-form field the post names nothing under (a stored row with no
  # parts, its last one removed) has no rows to upload for.
  defp upload_nested_images(field_name, params, socket, form) do
    case Map.get(params, to_string(field_name)) do
      nil -> {params, @no_uploads}
      _posted -> upload_posted_nested_images(field_name, params, socket, form)
    end
  end

  defp upload_posted_nested_images(field_name, params, socket, form) do
    nested_form = form.forms[field_name]

    {nested_params, tally} =
      Map.get(params, field_name |> to_string())
      |> upload_images(socket, nested_form)

    {Map.put(params, field_name |> to_string(), nested_params), tally}
  end

  defp upload_image(field, params, socket, form) do
    constraints = AttachmentUpload.attachment_constraints(field)
    upload_name = FormUploads.upload_name(socket.assigns, form, field)
    params = drop_blank_attachment_param(params, field)

    {uploaded_values, refused} = consume_attachment_entries(socket, upload_name, constraints)

    params =
      case {field.type, uploaded_values, form.data} do
        {_, [], nil} ->
          params

        {_, [], data} ->
          put_stored_attachment(params, field, data, socket, form)

        {AshQuick.AshTypes.Attachment, [value], _} ->
          params |> Map.put(field.name |> to_string(), value)

        {{:array, AshQuick.AshTypes.Attachment}, values, _} ->
          params
          |> Map.put(field.name |> to_string(), saved_before(field, params, form) ++ values)
      end

    {params, {refused, Enum.map(uploaded_values, &{&1["key"], upload_name})}}
  end

  # A save with no new upload keeps what the record holds, but only for the
  # record's own attachment attribute, or a single attachment argument standing
  # for it (`Utils.mirrors_attachment_attribute?/2`). Any other argument is the
  # action's: it takes its own default, never whatever the record holds under
  # the same name — a calculation, an aggregate or a relationship, unloaded or
  # of another type.
  defp put_stored_attachment(params, %Ash.Resource.Attribute{} = field, data, socket, form),
    do: Map.put_new(params, field.name |> to_string(), kept_attachment(field, data, socket, form))

  defp put_stored_attachment(params, argument, data, socket, form) do
    if Utils.mirrors_attachment_attribute?(form.resource, argument),
      do:
        put_stored_attachment(
          params,
          Ash.Resource.Info.attribute(form.resource, argument.name),
          data,
          socket,
          form
        ),
      else: params
  end

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
    key =
      AttachmentUpload.build_attachment_key(
        entry,
        socket,
        Keyword.fetch!(constraints, :visibility)
      )

    case store_socket_upload(meta, key, entry, socket, constraints) do
      :ok -> {:ok, attachment_params(key, entry)}
      :error -> {:ok, :not_stored}
    end
  end

  # A presign that failed leaves its entry `valid?`, but with an upload error.
  # A row a save brings that no change brought before has no upload yet, and
  # so no entries.
  defp valid_entries(socket, upload_name) do
    case socket.assigns.uploads[upload_name] do
      nil ->
        []

      conf ->
        Enum.filter(
          conf.entries,
          &(&1.valid? and Phoenix.Component.upload_errors(conf, &1) == [])
        )
    end
  end

  defp attachment_params(key, entry) do
    file_type = AttachmentUpload.infer_attachment_file_type(entry.client_name)

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
    media_type = AttachmentUpload.accepted_media_type(entry, constraints)

    with {:ok, write_key} <-
           Storage.object_arriving(
             serving_key,
             AttachmentUpload.arriving_opts(entry, socket, constraints, media_type)
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
  @doc false
  def reference_attachments(%Ash.Changeset{} = changeset, scope) do
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
  def reference_attachments(source, _scope), do: source

  defp attachment_keys(record), do: Storage.attachment_keys(record)
end
