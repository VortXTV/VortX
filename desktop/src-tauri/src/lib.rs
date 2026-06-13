// StremioX desktop app logic. Kept in a lib (Tauri 2 convention) so the same entry point can host
// mobile targets later. The shared stremio-core engine and the libmpv player are wired in here in a
// later iteration, behind Tauri commands the frontend calls.

/// A Tauri command the frontend can invoke. Placeholder until the engine lands; proves IPC works.
#[tauri::command]
fn engine_status() -> &'static str {
    "scaffold"
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![engine_status])
        .run(tauri::generate_context!())
        .expect("error while running the StremioX desktop app");
}
