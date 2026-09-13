// A browser session is one tab's sign-in. sessionStorage — not a cookie, not the
// user record — is what makes that true: every tab gets its own, and closing one
// ends it.
//
// Both values here have to be in the connect params before the socket connects,
// which is why this is a module the host spreads into `params` rather than a
// hook: a hook binds to a DOM element inside an already-connected socket.
const TAB_KEY = "ash_quick:tab"
const IMPERSONATION_KEY = "ash_quick:impersonation"

// The tab's own identity. The server cannot mint it — a refresh or a reconnect
// hands it a brand new process, and it would have no way to tell that apart from
// a second tab opening. Minted here once and replayed, so the register counts
// tabs rather than reconnects.
//
// `started_at` is this tab's claim about itself and is shown, never trusted: it
// says when somebody opened a tab, which is not a privilege anyone holds. The
// one timestamp a decision rests on — when an impersonation began — comes out of
// the signed token instead.
function tab() {
  const stored = sessionStorage.getItem(TAB_KEY)
  if (stored) return JSON.parse(stored)

  const tab = { id: crypto.randomUUID(), started_at: new Date().toISOString() }
  sessionStorage.setItem(TAB_KEY, JSON.stringify(tab))
  return tab
}

// Spread into the LiveSocket's `params`, which must stay a function so each
// (re)connect re-reads both.
export function browserSessionParams() {
  return { tab: tab(), impersonation: sessionStorage.getItem(IMPERSONATION_KEY) }
}

// The DOM events this module owns. Dispatch them from your own menu markup:
//
//     <.link phx-click={JS.dispatch("ash_quick:end-impersonation")}>End Impersonation</.link>
//     <a href={~p"/sign-out"} phx-click={JS.dispatch("ash_quick:clear-impersonation")}>Sign out</a>
export function initBrowserSession(liveSocket) {
  // Reconnecting is what applies a change: every LiveView remounts and reads the
  // new connect params. Cheaper and less jarring than reloading the page, and it
  // leaves the other tabs connected as whoever they already were.
  const reconnectSocket = () => liveSocket.disconnect(() => liveSocket.connect())

  // A destination means somebody started this from the register, to go and look
  // at the page the other person is on. Navigating first and reconnecting on
  // arrival is what makes the tab land there already being them, rather than
  // arriving as itself and swapping under the reader.
  window.addEventListener("phx:impersonate", event => {
    sessionStorage.setItem(IMPERSONATION_KEY, event.detail.token)

    if (event.detail.to) {
      window.location.assign(event.detail.to)
    } else {
      reconnectSocket()
    }
  })

  // Ending it from the user menu, and being ended by somebody watching the live
  // sessions, are the same thing from here: drop the token, come back as
  // whoever the session really is.
  const endImpersonation = () => {
    sessionStorage.removeItem(IMPERSONATION_KEY)
    reconnectSocket()
  }

  window.addEventListener("ash_quick:end-impersonation", endImpersonation)
  window.addEventListener("phx:end-impersonation", endImpersonation)

  const clearImpersonation = () => sessionStorage.removeItem(IMPERSONATION_KEY)

  // Neither of these reconnects: the first arrives on a mount that already
  // resolved to the real user, and the second is followed by a full page load.
  //
  // The server refused the token, so stop replaying it.
  window.addEventListener("phx:clear-impersonation", clearImpersonation)

  // Signing out ends the tab's impersonation with it. sessionStorage outlives the
  // session cookie, so the next login here would otherwise silently resume it.
  window.addEventListener("ash_quick:clear-impersonation", clearImpersonation)
}
