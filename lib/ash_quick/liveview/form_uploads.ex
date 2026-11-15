defmodule AshQuick.LiveView.FormUploads do
  @moduledoc false
  # The uploads a form allows: one per attachment field, at any depth, under a
  # name a sub-form keeps across renumbering, written by the browser or over
  # the socket.
  import Phoenix.LiveView, only: [allow_upload: 3, cancel_upload: 3]
  import Phoenix.Component, only: [assign: 3]
  alias AshQuick.LiveView.AttachmentUpload
  alias AshQuick.LiveView.FormAttachments
  alias AshQuick.LiveView.Utils
  alias AshQuick.Storage

  # The name each sub-form's uploads were allowed under (`upload_name/3`).
  @upload_names :ash_quick_upload_names

  # A new form starts without any.
  @doc false
  def clear_upload_names(socket), do: assign(socket, @upload_names, %{})

  @doc false
  def allow_image_upload(socket, nil), do: socket

  def allow_image_upload(socket, form) do
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
        constraints = AttachmentUpload.attachment_constraints(field)
        accepts = Keyword.fetch!(constraints, :accepts)

        allow_upload(
          socket,
          upload_name,
          [
            accept: AttachmentUpload.attachment_accept_extensions(accepts),
            max_entries: if(field.type == AshQuick.AshTypes.Attachment, do: 1, else: 10),
            max_file_size: AttachmentUpload.attachment_max_bytes(constraints),
            auto_upload: true,
            validator: &AttachmentUpload.validate_attachment_entry(&1, constraints),
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

  @doc false
  def upload_name(assigns, form, field) do
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
  @doc false
  def follow_removed_sub_form(socket, held, form, path) do
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
        [
          external: fn entry, socket ->
            AttachmentUpload.presign_attachment_upload(entry, socket, constraints)
          end
        ]

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
      {:noreply,
       FormAttachments.consume_completed_upload(socket, upload_name, field, constraints)}
    end
  end
end
