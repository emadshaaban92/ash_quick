defmodule AshQuick.StorageLifecycleTest do
  @moduledoc """
  The lifecycle callbacks on `AshQuick.Storage` are optional. A storage module
  that implements them — the fixture host's, here — decides where bytes go and
  what is servable; one that leaves them out gets the passthrough, and
  `url_for/2` serves everything.

  `async: false` because the second half swaps the `:storage` config, which
  every concurrent `url_for/2` in the suite reads.
  """
  use ExUnit.Case, async: false

  alias AshQuick.AshTypes.Attachment.Value
  alias AshQuick.Storage

  defp with_storage(module, fun) do
    original = Application.get_env(:ash_quick, :storage)

    Application.put_env(:ash_quick, :storage, module)

    try do
      fun.()
    after
      Application.put_env(:ash_quick, :storage, original)
    end
  end

  test "a storage module with the lifecycle callbacks is asked; one without gets the passthrough" do
    key = "public/lifecycle/#{:erlang.unique_integer([:positive])}.jpg"
    value = %Value{key: key, file_type: :image}

    # The host's storage takes custody: the bytes are routed elsewhere and the
    # object is withheld until the pipeline promotes it.
    assert {:ok, write_key} = Storage.object_arriving(key, source: :upload_form)
    assert write_key != key
    assert Storage.object_states([key]) == %{key => :processing}
    assert Storage.url_for(value) == :processing

    # `AshQuick.Storage.S3` implements none of the three, so the same key —
    # still `:processing` as far as the host's rows are concerned — is served.
    with_storage(AshQuick.Storage.S3, fn ->
      assert Storage.object_arriving(key, source: :upload_form) == {:ok, key}
      assert Storage.object_states([key]) == %{}
      assert Storage.object_referenced([key], AshQuick.StorageLifecycleTest, nil) == :ok
      assert {:ok, url} = Storage.url_for(value)
      assert url =~ key
    end)
  end
end
