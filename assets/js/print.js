// Receives the PDF an action printed (AshQuick.Print) over the LiveView socket
// and saves it or sends it to the print dialog. It never touches a URL anyone
// else could open: the bytes live in this tab, as a blob, until they are used.
//
//     import { initPrinting } from "../../deps/ash_quick/assets/js/print"
//     initPrinting()

export function initPrinting() {
    window.addEventListener("phx:ash_quick:pdf", ({ detail }) => {
        const url = URL.createObjectURL(pdfBlob(detail.data));
        if (detail.delivery === "print") printPdf(url);
        else downloadPdf(url, detail.filename);
    });
}

function pdfBlob(base64) {
    const bytes = Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
    return new Blob([bytes], { type: "application/pdf" });
}

function downloadPdf(url, filename) {
    const link = document.createElement("a");
    link.href = url;
    link.download = filename;
    document.body.appendChild(link);
    link.click();
    link.remove();
    // The download has its own copy by the time the click returns.
    setTimeout(() => URL.revokeObjectURL(url), 1000);
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
