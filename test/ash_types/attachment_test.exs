defmodule AshQuick.AshTypes.AttachmentTest do
  use ExUnit.Case, async: true

  alias AshQuick.AshTypes.Attachment
  alias AshQuick.AshTypes.Attachment.Value

  @public_constraints [visibility: :public, accepts: [:image]]
  @private_constraints [visibility: :private, accepts: [:image, :video], max_size_mb: 50]

  describe "storage_type/1" do
    test "is :map (JSONB on Postgres)" do
      assert Attachment.storage_type(nil) == :map
    end
  end

  describe "constraints/0" do
    test "declares visibility, accepts, max_size_mb" do
      keys = Attachment.constraints() |> Keyword.keys()
      assert :visibility in keys
      assert :accepts in keys
      assert :max_size_mb in keys
    end

    test "max_size_mb defaults to 50" do
      assert Attachment.constraints()[:max_size_mb][:default] == 50
    end
  end

  describe "cast_input/2" do
    test "passes through nil" do
      assert {:ok, nil} = Attachment.cast_input(nil, @public_constraints)
    end

    test "passes through a Value struct unchanged" do
      value = %Value{key: "public/products/abc.jpg", file_type: :image}
      assert {:ok, ^value} = Attachment.cast_input(value, @public_constraints)
    end

    test "casts an atom-keyed map into a Value" do
      input = %{
        key: "public/products/abc.jpg",
        file_type: :image,
        original_filename: "photo.jpg",
        byte_size: 12_345
      }

      assert {:ok,
              %Value{
                key: "public/products/abc.jpg",
                file_type: :image,
                original_filename: "photo.jpg",
                byte_size: 12_345
              }} = Attachment.cast_input(input, @public_constraints)
    end

    test "casts a string-keyed map (form params) into a Value" do
      input = %{
        "key" => "private/return_requests/abc.mp4",
        "file_type" => "video",
        "original_filename" => "evidence.mp4",
        "byte_size" => 1_000_000
      }

      assert {:ok,
              %Value{
                key: "private/return_requests/abc.mp4",
                file_type: :video,
                original_filename: "evidence.mp4",
                byte_size: 1_000_000
              }} = Attachment.cast_input(input, @private_constraints)
    end

    test "rejects a map without a key" do
      assert :error = Attachment.cast_input(%{file_type: :image}, @public_constraints)
    end

    test "rejects non-map, non-struct input" do
      assert :error = Attachment.cast_input(42, @public_constraints)
    end

    test "casts an empty string into nil (form-clear case)" do
      assert {:ok, nil} = Attachment.cast_input("", @public_constraints)
    end

    test "casts a JSON-encoded string into a Value (hidden-input round-trip)" do
      json =
        Jason.encode!(%{
          key: "public/products/abc.jpg",
          file_type: "image",
          original_filename: "abc.jpg",
          byte_size: 200
        })

      assert {:ok,
              %Value{
                key: "public/products/abc.jpg",
                file_type: :image,
                original_filename: "abc.jpg",
                byte_size: 200
              }} = Attachment.cast_input(json, @public_constraints)
    end

    test "rejects a non-JSON binary" do
      assert :error = Attachment.cast_input("not json", @public_constraints)
    end
  end

  describe "cast_stored/2" do
    test "round-trips a JSONB-style string-keyed map" do
      stored = %{
        "key" => "public/products/x.jpg",
        "file_type" => "image",
        "original_filename" => nil,
        "byte_size" => nil
      }

      assert {:ok,
              %Value{
                key: "public/products/x.jpg",
                file_type: :image,
                original_filename: nil,
                byte_size: nil
              }} = Attachment.cast_stored(stored, @public_constraints)
    end

    test "passes through nil" do
      assert {:ok, nil} = Attachment.cast_stored(nil, @public_constraints)
    end
  end

  describe "dump_to_native/2" do
    test "dumps a Value to a plain map (JSONB-friendly)" do
      value = %Value{
        key: "public/products/x.jpg",
        file_type: :image,
        original_filename: "x.jpg",
        byte_size: 100
      }

      assert {:ok,
              %{
                key: "public/products/x.jpg",
                file_type: :image,
                original_filename: "x.jpg",
                byte_size: 100
              }} = Attachment.dump_to_native(value, @public_constraints)
    end

    test "round-trips: cast_input -> dump -> cast_stored gives the same Value" do
      input = %{
        "key" => "public/products/abc.jpg",
        "file_type" => "image",
        "original_filename" => "abc.jpg",
        "byte_size" => 200
      }

      {:ok, value} = Attachment.cast_input(input, @public_constraints)
      {:ok, dumped} = Attachment.dump_to_native(value, @public_constraints)
      {:ok, restored} = Attachment.cast_stored(dumped, @public_constraints)

      assert restored == value
    end
  end

  describe "apply_constraints/2" do
    test "accepts a value whose key prefix matches the visibility" do
      value = %Value{key: "public/products/x.jpg", file_type: :image}
      assert {:ok, ^value} = Attachment.apply_constraints(value, @public_constraints)
    end

    test "rejects a value whose key prefix does not match the visibility" do
      value = %Value{key: "private/products/x.jpg", file_type: :image}

      assert {:error, errors} = Attachment.apply_constraints(value, @public_constraints)
      assert Enum.any?(errors, fn err -> err[:field] == :key end)
    end

    test "rejects a value whose file_type is not in :accepts" do
      value = %Value{key: "public/products/x.mp4", file_type: :video}

      assert {:error, errors} = Attachment.apply_constraints(value, @public_constraints)
      assert Enum.any?(errors, fn err -> err[:field] == :file_type end)
    end

    test "accepts a value whose file_type is in :accepts" do
      value = %Value{key: "private/return_requests/x.mp4", file_type: :video}
      assert {:ok, ^value} = Attachment.apply_constraints(value, @private_constraints)
    end

    test "skips file_type validation when file_type is nil (best-effort field)" do
      value = %Value{key: "public/products/x.jpg", file_type: nil}
      assert {:ok, ^value} = Attachment.apply_constraints(value, @public_constraints)
    end

    test "passes through nil" do
      assert {:ok, nil} = Attachment.apply_constraints(nil, @public_constraints)
    end
  end
end
