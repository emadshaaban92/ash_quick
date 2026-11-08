defmodule AshQuick.Check.Storage do
  @moduledoc false
  # The router held to where a store that serves objects from the
  # application's origin (`AshQuick.Storage.Local`, `AshQuick.Storage.S3.Proxy`)
  # builds its URLs.
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
  alias AshQuick.Storage.S3.Proxy

  # Each store that serves its own objects, with the plug that serves them.
  @served [{Local, Local.Plug}, {Proxy, Proxy.Plug}]

  def run(router, storage \\ AshQuick.Config.storage()) do
    case Enum.find(@served, fn {store, _plug} -> store.backs?(storage) end) do
      nil ->
        {[], []}

      {store, _plug} when is_nil(router) ->
        {[], [{:storage, "no router was given, so #{inspect(store)}'s forward was not read"}]}

      {store, plug} ->
        {findings(router, store, plug, store.at([])), []}
    end
  end

  defp findings(router, store, plug, at) do
    case Phoenix.Router.route_info(router, "GET", at <> "/public/probe", nil) do
      %{plug: ^plug, pipe_through: []} -> []
      %{plug: ^plug, pipe_through: pipes} -> [piped(router, plug, at, pipes)]
      _other -> [unserved(router, store, plug, at)]
    end
  end

  defp unserved(router, store, plug, at) do
    %Finding{
      check: :unserved_storage,
      subject: at,
      message: """
      `:storage` keeps its objects through #{inspect(store)}, which \
      builds every URL under #{at}, but #{inspect(router)} does not route \
      #{at} to #{inspect(plug)}.

      Every attachment renders as a broken link and every export's download \
      fails. Forward the path, outside any pipeline:

          forward "#{at}", #{inspect(plug)}

      or set `:at` under `config :ash_quick, #{inspect(store)}` to the \
      path the forward is at.
      """
    }
  end

  defp piped(router, plug, at, pipes) do
    %Finding{
      check: :piped_storage,
      subject: at,
      message: """
      #{inspect(router)} forwards #{at} to #{inspect(plug)} \
      through #{inspect(pipes)}.

      What opens an object is the token on its link, not the session. A \
      pipeline's plugs run first: `accepts ["html"]` refuses an image \
      request, and a sign-in check refuses a link handed to someone without \
      a session. Move the forward to a scope with no `pipe_through`.
      """
    }
  end
end
