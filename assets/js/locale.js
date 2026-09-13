// `<html lang>` and `<html dir>` are written by the dead render, which resolves
// to whoever the session really is: a tab's impersonation reaches the server
// only in the LiveSocket connect params, so the HTTP response cannot know the
// page is about to be somebody else's — nor which way it then runs.
//
// The connected mount is the first moment that is known, and `<html>` is
// outside every LiveView, so no patch or navigation would ever correct it.
// The server pushes what the page is actually in; this applies it.
export function initLocale() {
  window.addEventListener("phx:locale", event => {
    const { lang, dir } = event.detail

    if (lang) document.documentElement.lang = lang
    if (dir) document.documentElement.dir = dir
  })
}
