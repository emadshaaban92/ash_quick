defmodule Example.Uploads.Quarantine do
  @moduledoc """
  Where an object waits while the host decides whether to serve it.

  The record stores the **serving** key from the moment it is saved; the
  quarantine key is that key with `quarantine/` prepended — the whole key,
  untouched, moved under one prefix:

      serving:     public/products/<uuid>-<slug>
      quarantine:  quarantine/public/products/<uuid>-<slug>

  Prepending rather than replacing the leading segment is deliberate. It is
  injective, so `public/products/X` and `private/products/X` cannot collapse
  onto one quarantine key; it leaves the key self-describing, so an orphan in
  the bucket says what it was going to become; and it assumes nothing about key
  shape.

  Nesting `public/` under `quarantine/` is safe only because anonymous
  `GetObject` is granted on `public/*` **anchored at the start of the key** —
  the contract `AshQuick.Storage` documents. A bucket policy written with a
  leading wildcard would make every quarantined object anonymously readable,
  which is the one thing quarantine exists to prevent.
  """

  @prefix "quarantine/"

  @doc "The prefix every quarantined object lives under."
  def prefix, do: @prefix

  @doc """
  The quarantine key for a serving key. Idempotent — a key already under
  quarantine comes back unchanged.
  """
  def key(@prefix <> _rest = quarantine_key), do: quarantine_key
  def key(serving_key) when is_binary(serving_key), do: @prefix <> serving_key

  @doc "The serving key a quarantine key is destined for."
  def serving_key(key) when is_binary(key), do: String.replace_prefix(key, @prefix, "")

  @doc "True when `key` names an object still under quarantine."
  def quarantined?(@prefix <> _rest), do: true
  def quarantined?(_key), do: false
end
