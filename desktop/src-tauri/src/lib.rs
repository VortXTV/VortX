// StremioX desktop app logic. Kept in a lib (Tauri 2 convention) so the same entry point can host
// mobile targets later. The shared stremio-core engine embeds directly here (the backend is Rust,
// no FFI); the libmpv player and the full command surface that drives the Runtime land on top of
// the `engine` module's cross-platform Env.

mod engine;

/// Proves the embedded engine links and is callable from the frontend: returns stremio-core's
/// storage schema version. The full init/dispatch/get_state command surface (mirroring the Apple
/// core's FFI) builds on `engine::DesktopEnv` next.
#[tauri::command]
fn engine_schema_version() -> u32 {
    stremio_core::constants::SCHEMA_VERSION
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .invoke_handler(tauri::generate_handler![engine_schema_version])
        .run(tauri::generate_context!())
        .expect("error while running the StremioX desktop app");
}
