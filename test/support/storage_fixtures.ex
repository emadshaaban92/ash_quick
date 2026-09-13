defmodule AshQuick.Test.Uploads.Domain do
  @moduledoc "Holds the row the fixture storage seam keeps custody in."
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    allow_unregistered? true
  end
end

defmodule AshQuick.Test.Uploads.StoredObject do
  @moduledoc """
  What the fixture host records when it takes custody of an object.

  A host that intercepts the write key has to remember it did, or
  `object_states/1` has nothing to answer from — so the seam needs somewhere to
  keep that, and this is it. `private? true` keeps one test's objects out of
  another's.
  """
  use Ash.Resource, domain: AshQuick.Test.Uploads.Domain, data_layer: Ash.DataLayer.Ets

  ets do
    private? true
  end

  attributes do
    uuid_primary_key :id
    attribute :serving_key, :string, public?: true, allow_nil?: false

    attribute :state, :atom,
      public?: true,
      constraints: [one_of: [:processing, :ready, :rejected]]
  end

  actions do
    default_accept [:serving_key, :state]
    defaults [:read, :create, :update]
  end
end

defmodule AshQuick.Test.Uploads.ObjectStore do
  @moduledoc """
  A host's storage seam: its own bucket, and all three lifecycle callbacks.

  Two things are being stood in for at once.

  The **bucket** half is why it names a bucket of its own rather than
  `AshQuick.Config.s3_bucket/0`. A host that already owns an object-store
  client points `:storage` here and keeps one bucket across both; the library
  must hold no second opinion about which bucket an object is in. The two are
  deliberately different values so a URL built from the wrong one is visible.

  The **lifecycle** half is why it implements `object_arriving/2`,
  `object_states/1` and `object_referenced/3`. It takes custody by routing the
  bytes to a quarantine prefix and withholding the object until something
  promotes it — the shape of a host that scans or transcodes before serving.
  `AshQuick.Storage.S3` implements none of the three and is the other side of
  that comparison: the passthrough, where every object is servable.
  """
  @behaviour AshQuick.Storage

  require Ash.Query

  alias AshQuick.Test.Uploads.StoredObject

  @quarantine_prefix "quarantine/"

  @doc "The one bucket this host names. Deliberately not `AshQuick.Config.s3_bucket/0`."
  def bucket, do: "ash-quick-host-bucket"

  @doc "The host public URLs are built against."
  def host, do: "s3.host.invalid"

  @impl true
  def public_url(key), do: AshQuick.Storage.S3.public_url(bucket(), host(), key)

  @impl true
  def presigned_put_url(key, opts), do: AshQuick.Storage.S3.presigned_put_url(bucket(), key, opts)

  @impl true
  def presigned_get_url(key, opts), do: AshQuick.Storage.S3.presigned_get_url(bucket(), key, opts)

  @impl true
  def upload(key, path, opts), do: AshQuick.Storage.S3.upload(bucket(), key, path, opts)

  @impl true
  def object_arriving(serving_key, _opts) do
    StoredObject
    |> Ash.Changeset.for_create(:create, %{serving_key: serving_key, state: :processing})
    |> Ash.create!()

    {:ok, @quarantine_prefix <> serving_key}
  end

  @impl true
  def object_states(keys) do
    StoredObject
    |> Ash.Query.filter(serving_key in ^keys)
    |> Ash.read!()
    |> Map.new(&{&1.serving_key, &1.state})
  end

  @impl true
  def object_referenced(_keys, _resource, _resource_id), do: :ok

  @doc """
  Releases `serving_key`, as the host's own pipeline would once whatever it was
  holding the object for finished.
  """
  def promote!(serving_key) do
    StoredObject
    |> Ash.Query.filter(serving_key == ^serving_key)
    |> Ash.read!()
    |> Enum.each(&(&1 |> Ash.Changeset.for_update(:update, %{state: :ready}) |> Ash.update!()))

    :ok
  end
end
