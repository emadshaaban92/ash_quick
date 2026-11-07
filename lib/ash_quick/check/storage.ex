defmodule AshQuick.Check.Storage do
  @moduledoc false
  # The router held to where `AshQuick.Storage.Local` builds its URLs.
  #
  # The storage reads its `:at` from configuration, and the forward that serves
  # it is written in the router, so the two can drift apart with nothing to say
  # so: every image becomes a broken link, and an export's download a 404. A
  # forward inside a pipeline is as bad, more quietly: `:browser`'s `accepts`
  # turns an image request away, and a session-only plug turns away the link
  # that was meant to work for whoever holds it.
  #
  # Asked through `Phoenix.Router.route_info/4` with a path under `:at`, which
  # answers the route the request would really take, scope prefixes and
  # pipelines included.

  alias AshQuick.Check.Finding
  alias AshQuick.Storage.Local

  def run(router, storage \\ AshQuick.Config.storage()) do
    cond do
      not Local.backs?(storage) ->
        {[], []}

      is_nil(router) ->
        {[], [{:storage, "no router was given, so the local storage's forward was not read"}]}

      true ->
        {findings(router, Local.at([])), []}
    end
  end

  defp findings(router, at) do
    case Phoenix.Router.route_info(router, "GET", at <> "/public/probe", nil) do
      %{plug: Local.Plug, pipe_through: []} -> []
      %{plug: Local.Plug, pipe_through: pipes} -> [piped(router, at, pipes)]
      _other -> [unserved(router, at)]
    end
  end

  defp unserved(router, at) do
    %Finding{
      check: :unserved_local_storage,
      subject: at,
      message: """
      `:storage` keeps its objects through AshQuick.Storage.Local, which \
      builds every URL under #{at}, but #{inspect(router)} does not route \
      #{at} to AshQuick.Storage.Local.Plug.

      Every attachment renders as a broken link and every export's download \
      fails. Forward the path, outside any pipeline:

          forward "#{at}", AshQuick.Storage.Local.Plug

      or set `:at` under `config :ash_quick, AshQuick.Storage.Local` to the \
      path the forward is at.
      """
    }
  end

  defp piped(router, at, pipes) do
    %Finding{
      check: :piped_local_storage,
      subject: at,
      message: """
      #{inspect(router)} forwards #{at} to AshQuick.Storage.Local.Plug \
      through #{inspect(pipes)}.

      What opens an object is the token on its link, not the session. A \
      pipeline's plugs run first: `accepts ["html"]` refuses an image \
      request, and a sign-in check refuses a link handed to someone without \
      a session. Move the forward to a scope with no `pipe_through`.
      """
    }
  end
end
