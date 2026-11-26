defmodule AshQuick.LiveView.AttachmentKeys do
  @moduledoc false
  # The attachment keys a form takes back from a post: those it issued when it
  # was built and those this page minted for an upload, each held to its
  # top-level field.
  require Logger
  import Phoenix.Component, only: [assign: 2]
  alias AshQuick.LiveView.FormParams
  alias AshQuick.LiveView.SubForms
  alias AshQuick.LiveView.FormUploads
  alias AshQuick.Storage

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
  @doc false
  def assign_issued_attachment_keys(socket) do
    socket
    |> assign(
      ash_quick_issued_attachment_keys: attachment_keys_by_field(socket.assigns.form, true)
    )
    |> assign(ash_quick_minted_attachment_keys: %{})
    |> FormUploads.clear_upload_names()
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
  @doc false
  def mint_attachment_key(%Phoenix.LiveView.Socket{} = socket, key, upload_name) do
    minted = Map.get(socket.assigns, :ash_quick_minted_attachment_keys, %{})
    field = upload_field(socket.assigns[:form], upload_name)
    assign(socket, ash_quick_minted_attachment_keys: Map.put(minted, key, field))
  end

  # Called outside a LiveView there is no form to take the key back.
  def mint_attachment_key(socket, _key, _upload_name), do: socket

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
  @doc false
  def validate_issued(form, params, socket) do
    validated = SubForms.validate(form, params)

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
        validated = SubForms.validate(form, params)

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
    |> FormParams.carry_embedded_params(form)
  end
end
