// Receives a file an action produced (the `:ash_quick_download` mark, see
// AshQuick.LiveView.DownloadUtils) over the LiveView socket and saves it under
// the name the action gave it. As with a printed PDF, the bytes live in this
// tab, as a blob, until they are saved: no URL anyone else could open.
let listening = false

// Once per page, however many sockets are built: a second listener would save
// every file twice.
export function listenForDownloads() {
    if (listening) return;
    listening = true;

    window.addEventListener("phx:ash_quick:download", ({ detail }) => {
        saveFile(fileUrl(detail.data, detail.content_type), detail.filename);
    });
}

// An object URL over the base64 `data` an event carries, typed as `type`.
export function fileUrl(base64, type) {
    const bytes = Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
    return URL.createObjectURL(new Blob([bytes], { type }));
}

export function saveFile(url, filename) {
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    // The download has its own copy by the time the click returns.
    setTimeout(() => URL.revokeObjectURL(url), 1000);
}
