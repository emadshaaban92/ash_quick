defmodule ExampleWeb.HostConformanceTest do
  @moduledoc """
  The contracts AshQuick asks of the application around it, asserted rather than
  assumed.

  Each of these fails silently in production if it is wrong: a scope that
  satisfies neither protocol leaves audit rows with no real actor, a socket
  without `:peer_data` leaves every audited write with no address, and a
  storage module the config names but that implements nothing serves objects
  the host is still holding. The library provides the probe for each; this is
  where the application uses it.
  """
  use ExUnit.Case, async: true

  # What `ExampleWeb.RouterTest` used to assert by hand, and every resource-level
  # convention beside it. The whole point of the task is that a host gets these
  # without writing them, so this app gets them the same way an adopter does —
  # and `skipped` being empty is what says every check really ran, rather than
  # passing for want of anything to compare against.
  test "the application diverges from none of AshQuick's conventions" do
    report = AshQuick.Check.run(otp_app: :example)

    assert report.skipped == []
    assert report.findings == [], AshQuick.Check.format(report)
  end

  test "the scope satisfies both halves of the provenance contract" do
    assert AshQuick.Scope.contract_violations(Example.Scope) == []
  end

  test "the endpoint's socket carries what the mount reads an address from" do
    assert AshQuick.LiveView.Mount.connect_info_violations(ExampleWeb.Endpoint) == []
  end

  test "the modules this application supplies by name are the ones it wired" do
    assert AshQuick.Config.actor_resource() == Example.Accounts.User
    assert AshQuick.Config.audit_resource() == Example.Accounts.AuditLog
    assert AshQuick.Config.nav() == ExampleWeb.Nav
    assert AshQuick.Config.endpoint() == ExampleWeb.Endpoint
  end

  test "the storage seam is this application's, not the library's default" do
    assert AshQuick.Config.storage() == Example.Uploads.ObjectStore

    # And it is really reached, rather than the config merely naming it: the
    # URL is built against the host's bucket, which is deliberately not the one
    # `AshQuick.Storage.S3` would fall back to.
    refute Example.Uploads.ObjectStore.bucket() == AshQuick.Config.s3_bucket()

    value = %AshQuick.AshTypes.Attachment.Value{key: "public/products/x.jpg"}

    assert {:ok, url} = AshQuick.Storage.url_for(value)
    assert url =~ Example.Uploads.ObjectStore.bucket()
    refute url =~ AshQuick.Config.s3_bucket()
  end

  test "export is on and print is off, which is what this app's dependencies say" do
    # `chromic_pdf` is deliberately not a dependency — see `mix.exs`. The print
    # control is absent rather than broken, which is the behaviour worth pinning.
    assert AshQuick.Config.exports_enabled?()
    refute AshQuick.Config.print_enabled?()
  end
end
