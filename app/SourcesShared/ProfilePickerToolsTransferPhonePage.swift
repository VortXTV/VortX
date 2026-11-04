import Foundation

/// Fixed self-contained bytes. No server interpolation of capability, owner or file metadata.
enum ProfilePickerToolsTransferPhonePage {
    static let script = #"""
"use strict";
(() => {
  const MAX = 10 * 1024 * 1024;
  const message = document.getElementById("message");
  const status = document.getElementById("status");
  const upload = document.getElementById("upload");
  const download = document.getElementById("download");
  const chooser = document.getElementById("file");
  let capability = location.hash.slice(1);
  history.replaceState(null, "", "/");
  let stopped = false, busy = false, timer = null, lastPoll = -Infinity;
  let mode = null, stage = null;
  const started = performance.now();
  const valid = /^[0-9a-f]{32,128}$/.test(capability) && capability.length % 2 === 0;
  function text(value) { message.textContent = value; }
  function stop(value) {
    stopped = true; capability = ""; clearTimeout(timer); timer = null;
    upload.disabled = true; download.disabled = true; chooser.disabled = true;
    if (value) text(value);
  }
  function options(method) {
    return { method, headers: { Authorization: "Bearer " + capability },
      cache: "no-store", credentials: "omit", mode: "same-origin", redirect: "error",
      referrerPolicy: "no-referrer" };
  }
  function checkResponse(response) {
    if (!response.ok) throw new Error("refused");
    return response;
  }
  function render() {
    const inputMode = mode === "repair" || mode === "restore";
    chooser.hidden = !inputMode; upload.hidden = !inputMode;
    upload.disabled = stopped || busy || stage !== "waiting-for-file" || !chooser.files.length;
    chooser.disabled = stopped || busy || stage !== "waiting-for-file";
    download.hidden = mode === "restore";
    download.disabled = stopped || busy || stage !== "available";
    const labels = { "waiting-for-file": "Choose the encrypted backup file.",
      preparing: "TV is checking the file. Keep the TV screen open.",
      "review-on-tv": "Review and continue on the TV. Restore confirmation is on the TV only.",
      available: "TV has made one encrypted file available.",
      "local-send-complete": "TV finished sending. Check the download on your phone and save it there.",
      closed: "This transfer is closed. Continue on the TV." };
    status.textContent = labels[stage] || "Continue on the TV.";
  }
  function schedule(delay) {
    clearTimeout(timer);
    if (!stopped && !document.hidden) timer = setTimeout(poll, delay);
  }
  async function poll() {
    if (stopped || document.hidden) return;
    const now = performance.now();
    if (now - started >= 300000) { stop("Transfer expired. Continue on the TV and rescan its current QR."); return; }
    if (now - lastPoll < 1000) { schedule(1000 - (now - lastPoll)); return; }
    lastPoll = now;
    try {
      const response = checkResponse(await fetch("/state", options("GET")));
      // Only bounded, fixed server metadata is parsed. Uploaded files never pass through JSON.
      const body = await response.text();
      if (body.length > 256) throw new Error("state");
      const state = JSON.parse(body);
      if (!["download", "repair", "restore"].includes(state.mode) ||
          !["waiting-for-file", "preparing", "review-on-tv", "available", "local-send-complete", "closed"].includes(state.stage)) throw new Error("state");
      mode = state.mode; stage = state.stage; render();
      if (stage === "closed" || stage === "local-send-complete") { stop(); return; }
    } catch (_) { stop("Transfer unavailable. Continue on the TV and rescan its current QR."); return; }
    schedule(1000);
  }
  chooser.addEventListener("change", () => {
    const file = chooser.files[0];
    if (file && (file.size < 1 || file.size > MAX)) {
      text("Choose a nonempty file up to 10 MiB. The TV checks the actual received bytes.");
      chooser.value = "";
    } else { text("Your original file will remain unchanged."); }
    render();
  });
  upload.addEventListener("click", async () => {
    if (busy || stopped || stage !== "waiting-for-file") return;
    const file = chooser.files[0];
    if (!file || file.size < 1 || file.size > MAX) return;
    busy = true; render(); text("Sending the original file bytes to the TV…");
    try {
      const request = options("POST");
      request.headers["Content-Type"] = "application/octet-stream";
      request.body = file;
      checkResponse(await fetch("/input", request));
      text("File sent for TV checks. Continue on the TV; this does not confirm an account restore.");
      stage = "preparing";
    } catch (_) { stop("Upload did not finish. Use Retry on the TV after it finishes closing this attempt, then rescan."); }
    busy = false; render();
  });
  download.addEventListener("click", async () => {
    if (busy || stopped || stage !== "available") return;
    busy = true; render(); text("Receiving the encrypted file…");
    try {
      const response = checkResponse(await fetch("/file", options("GET")));
      const length = response.headers.get("Content-Length");
      if (!/^[1-9][0-9]{0,7}$/.test(length || "") || Number(length) > MAX) throw new Error("length");
      const blob = await response.blob();
      if (blob.size !== Number(length) || blob.size < 1 || blob.size > MAX) throw new Error("length");
      const link = document.createElement("a");
      const url = URL.createObjectURL(blob);
      link.href = url;
      link.download = mode === "repair" ? "vortx-account-repaired.json" : "vortx-account-backup.json";
      link.rel = "noreferrer";
      document.body.appendChild(link); link.click(); link.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60000);
      stop("Browser prepared a download. Check and save it on your phone. TV sending status does not confirm a saved file. For another attempt, use Retry same file on the TV and rescan.");
    } catch (_) { stop("Download did not finish. Use Retry same file on the TV after it closes this attempt, then rescan."); }
    busy = false;
  });
  document.addEventListener("visibilitychange", () => {
    clearTimeout(timer); timer = null;
    if (!document.hidden) schedule(Math.max(0, 1000 - (performance.now() - lastPoll)));
  });
  window.addEventListener("pagehide", () => stop());
  if (!valid) { stop("Rescan the current QR on the TV. Reloading loses this transfer capability."); return; }
  schedule(0);
})();
"""#
    static let style = #"""
body{font:17px system-ui,sans-serif;max-width:38rem;margin:2rem auto;padding:0 1rem;background:#10131c;color:#edf2ff}button,input{font:inherit;margin:.7rem 0;padding:.7rem;max-width:100%}button{display:block}p{line-height:1.5}button:disabled{opacity:.5}[hidden]{display:none!important}
"""#
    static let html = #"""
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="referrer" content="no-referrer"><title>VortX TV file transfer</title><style>
"""# + style + #"""
</style></head><body><h1>VortX TV file transfer</h1><p>Use a phone on the same trusted Wi-Fi. Keep the TV screen open.</p><p>This local HTTP connection does not encrypt transfer authority or outer file metadata, including preserved unknown fields. Use trusted Wi-Fi.</p><p id="status" role="status" aria-live="polite">Checking the transfer…</p><input id="file" type="file" accept=".json,application/json,application/octet-stream" aria-label="Encrypted account backup file" hidden disabled><button id="upload" hidden disabled>Send file to TV</button><button id="download" hidden disabled>Download encrypted file</button><p id="message" role="status" aria-live="polite">Your original file remains unchanged. Review and Restore confirmation stay on the TV.</p><noscript>JavaScript is needed. Open this QR in your phone browser with JavaScript enabled.</noscript><script>
"""# + script + #"""
</script></body></html>
"""#
    static var bytes: Data { Data(html.utf8) }
    static let contentSecurityPolicy = #"""
default-src 'none'; script-src 'sha256-1s61w8serRssnns+L3Rs45fa4cEuenjdjCUg5zzywlo='; style-src 'sha256-ucKjrAdUx47tyZnC8TVYmm13HTP2q1o/7ceuswwAPnc='; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; object-src 'none'
"""#

    enum Status: String { case ok = "200 OK", badRequest = "400 Bad Request", forbidden = "403 Forbidden", conflict = "409 Conflict", gone = "410 Gone", tooLarge = "413 Content Too Large" }
    enum BodyKind { case bootstrap, metadata, file(ProfilePickerToolsTransferPolicy.Filename) }
    /// All values are typed/fixed; untrusted filenames/header strings are never accepted.
    static func responseHead(status: Status, kind: BodyKind, byteCount: Int) throws -> Data {
        guard (0...ProfilePickerToolsTransferPolicy.maxFileBytes).contains(byteCount) else {
            throw ProfilePickerToolsTransferPolicy.Refusal.length
        }
        let type: String
        var attachment = ""
        switch kind {
        case .bootstrap:
            guard byteCount == bytes.count else { throw ProfilePickerToolsTransferPolicy.Refusal.length }
            type = "text/html; charset=utf-8"
        case .metadata:
            guard byteCount <= 256 else { throw ProfilePickerToolsTransferPolicy.Refusal.length }
            type = "application/json"
        case .file(let name):
            guard byteCount > 0 else { throw ProfilePickerToolsTransferPolicy.Refusal.length }
            type = "application/octet-stream"
            attachment = "Content-Disposition: attachment; filename=\"" + name.rawValue + "\"\r\n"
        }
        return Data(("HTTP/1.1 " + status.rawValue + "\r\nContent-Type: " + type
            + "\r\nContent-Length: " + String(byteCount) + "\r\n" + attachment
            + "Connection: close\r\nCache-Control: no-store\r\nPragma: no-cache\r\n"
            + "Referrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\n"
            + "X-Frame-Options: DENY\r\nContent-Security-Policy: " + contentSecurityPolicy + "\r\n\r\n").utf8)
    }
}
