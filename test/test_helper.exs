ExUnit.start()

# The bucket `AshQuick.Storage.S3.Proxy` is tested against, handed to it per
# test rather than configured for ExAws.
AshQuick.Test.S3BucketStub.start()
