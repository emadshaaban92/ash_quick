// The client half of AshQuick. A host keeps Phoenix's own LiveSocket, passes
// its options through `withAshQuick` and attaches the socket once it is built:
//
//     import {LiveSocket} from "phoenix_live_view"
//     import {withAshQuick, attachAshQuick} from "ash_quick"
//
//     const liveSocket = new LiveSocket("/live", Socket, withAshQuick({
//       params: {_csrf_token: csrfToken},
//       hooks: {...colocatedHooks},
//     }))
//     attachAshQuick(liveSocket)
//
// Two steps because the tab's identity and impersonation token have to be in
// the connect params before the socket exists, and the listeners that
// reconnect it need the socket.
import {hooks, uploaders} from "phoenix-colocated/ash_quick"
import {browserSessionParams, listenForImpersonation} from "./browser_session"
import {listenForLocale} from "./locale"
import {listenForDownloads} from "./download"
import {listenForPdfs} from "./print"

// The host's LiveSocket options with AshQuick's added: the tab's identity and
// token in `params`, the colocated hooks in `hooks` and `S3` in `uploaders`.
// The host's own hooks and uploaders come last, so one of the same name
// replaces AshQuick's.
export function withAshQuick(opts = {}) {
  return {
    ...opts,
    params: withBrowserSession(opts.params),
    hooks: {...hooks, ...opts.hooks},
    uploaders: {...uploaders, ...opts.uploaders},
  }
}

// Listens for the events the server pushes: starting and ending an
// impersonation (which reconnects every attached socket), the page's `lang`
// and `dir`, printed PDFs and the files actions produce. The listeners are
// registered once per page, however many times it is called.
export function attachAshQuick(liveSocket) {
  listenForImpersonation(liveSocket)
  listenForLocale()
  listenForPdfs()
  listenForDownloads()
  return liveSocket
}

// The host's params may be an object or a function; either way the result is a
// function, so every (re)connect re-reads the tab's identity and its token.
function withBrowserSession(params) {
  return (...args) => ({
    ...(typeof params === "function" ? params(...args) : params),
    ...browserSessionParams(),
  })
}
