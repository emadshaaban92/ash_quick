defmodule Example.Accounts.Locale do
  @moduledoc """
  The languages a person's pages can render in.

  Each is labelled in its own language, whatever the reader's: a person
  looking for theirs finds it as they write it. The labels are the enum's, so
  the language picker, the users list and the details page all read them
  without anything on a QuickView naming the field.
  """
  use Ash.Type.Enum,
    values: [
      en: [label: "English"],
      ar: [label: "العربية"]
    ]
end
