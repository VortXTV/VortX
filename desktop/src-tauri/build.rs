fn main() {
    // Generate a permission per shell command so capabilities/default.json can grant exactly these to
    // the VortX web origin and nothing else.
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&[
            "server_status",
            "server_base_url",
            "mpv_play",
            "mpv_set_paused",
            "mpv_seek_relative",
            "mpv_stop",
            "mpv_status",
        ]),
    ))
    .expect("failed to run the Tauri build script");
}
