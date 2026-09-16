defmodule Example.EmptyDatabaseTest do
  @moduledoc """
  The test database holds nothing but what a test put there.

  Every row a test writes lives inside the Ecto sandbox and is rolled back, so
  a count taken here sees only rows that were *committed* — which nothing in the
  suite does. A non-zero count means the demo seeds were run against
  `MIX_ENV=test` (`mix setup` and `mix ash.reset` both do, against whichever
  environment they are invoked in).

  This is worth a test of its own because of how quietly it goes wrong. Seeded
  rows are visible to every test at once, so a list page has records nobody
  created, a search matches a product the test never wrote, a page-size
  assertion counts strangers, and `refute_has` over a name the seeds happen to
  use fails for a reason nothing on screen explains. Positive assertions all
  keep passing, which is why this was found by writing a pagination test rather
  than by the suite going red.

      MIX_ENV=test mix ash.tear_down && MIX_ENV=test mix ash.setup

  is the fix, and `mix test` on its own never re-creates the problem.
  """
  # Not `Example.DataCase`: its setup creates the three role fixtures, and this
  # test would count them. A sandbox connection is all that is needed, and
  # nothing is put in it.
  use ExUnit.Case, async: true

  setup tags do
    Example.DataCase.setup_sandbox(tags)
    :ok
  end

  test "no resource has rows that outlive a test" do
    populated =
      for domain <- Application.fetch_env!(:example, :ash_domains),
          resource <- Ash.Domain.Info.resources(domain),
          Ash.Resource.Info.data_layer(resource) == AshPostgres.DataLayer,
          count = Ash.count!(resource, authorize?: false),
          count > 0 do
        "#{inspect(resource)}: #{count}"
      end

    assert populated == [],
           """
           The test database holds committed rows, which every test can see:

           #{Enum.join(populated, "\n")}

           Re-create it:

               MIX_ENV=test mix ash.tear_down && MIX_ENV=test mix ash.setup
           """
  end
end
