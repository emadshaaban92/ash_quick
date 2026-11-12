// Receives the PDF an action printed (AshQuick.Print) over the LiveView socket
// and saves it or sends it to the print dialog. It never touches a URL anyone
// else could open: the bytes live in this tab, as a blob, until they are used.
import { fileUrl, saveFile } from "./download"

let listening = false

// Once per page, however many sockets are built: a second listener would save
// or print every PDF twice.
export function listenForPdfs() {
    if (listening) return;
    listening = true;

    window.addEventListener("phx:ash_quick:pdf", ({ detail }) => {
        const url = fileUrl(detail.data, "application/pdf");
        if (detail.delivery === "print") printPdf(url);
        else saveFile(url, detail.filename);
    });
}

function printPdf(url) {
    const frame = document.createElement("iframe");

    // Off-screen rather than hidden: a PDF viewer that isn't laid out
    // doesn't print.
    Object.assign(frame.style, {
        position: "fixed",
        left: "-10000px",
        top: "0",
        width: "210mm",
        height: "297mm",
        border: "0",
    });

    const cleanUp = () => {
        URL.revokeObjectURL(url);
        frame.remove();
    };

    frame.addEventListener("load", () => {
        // The viewer needs a moment after load before it will print.
        setTimeout(() => {
            frame.contentWindow.focus();
            frame.contentWindow.print();
            // The dialog is modal; focus comes back when it closes. Kiosk
            // printing shows no dialog, so focus never leaves.
            window.addEventListener("focus", () => setTimeout(cleanUp, 1000), { once: true });
            setTimeout(cleanUp, 60000);
        }, 300);
    });

    frame.src = url;
    document.body.appendChild(frame);
}
