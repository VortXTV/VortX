//! `DesktopModel`, the app model the runtime drives. Ported from the Apple core's `TvosModel`
//! (core/src/model.rs) — the same trimmed `stremio-core-web::WebModel`: a `ctx` field (required by
//! `#[derive(Model)]`) plus one field per screen — with the Env swapped to `DesktopEnv`. Each field
//! serializes to plain JSON for the Tauri frontend (the same contract the Apple app uses, minus FFI).

use stremio_core::models::{
    catalog_with_filters::CatalogWithFilters,
    catalogs_with_extra::CatalogsWithExtra,
    common::Loadable,
    continue_watching_preview::ContinueWatchingPreview,
    ctx::Ctx,
    library_with_filters::{ContinueWatchingFilter, LibraryWithFilters, NotRemovedFilter},
    meta_details::MetaDetails,
    player::Player,
    streaming_server::StreamingServer,
};
use stremio_core::runtime::Effects;
use stremio_core::types::{
    events::DismissedEventsBucket, library::LibraryBucket, notifications::NotificationsBucket,
    profile::Profile, resource::MetaItemPreview, search_history::SearchHistoryBucket,
    server_urls::ServerUrlsBucket, streams::StreamsBucket,
};
use stremio_core::Model;

use crate::engine::DesktopEnv;

#[derive(Model, Clone)]
#[model(DesktopEnv)]
pub struct DesktopModel {
    pub ctx: Ctx,
    /// Home "Continue Watching" rail, auto-derived from ctx.library + notifications (no load action).
    pub continue_watching_preview: ContinueWatchingPreview,
    /// Home board, every catalog of every installed addon (ActionLoad::CatalogsWithExtra).
    pub board: CatalogsWithExtra,
    /// Search results across the installed addons (ActionLoad::CatalogsWithExtra with a search extra).
    pub search: CatalogsWithExtra,
    pub discover: CatalogWithFilters<MetaItemPreview>,
    pub library: LibraryWithFilters<NotRemovedFilter>,
    pub continue_watching: LibraryWithFilters<ContinueWatchingFilter>,
    pub meta_details: MetaDetails,
    pub streaming_server: StreamingServer,
    pub player: Player,
}

impl DesktopModel {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        profile: Profile,
        library: LibraryBucket,
        streams: StreamsBucket,
        streaming_server_urls: ServerUrlsBucket,
        notifications: NotificationsBucket,
        search_history: SearchHistoryBucket,
        dismissed_events: DismissedEventsBucket,
    ) -> (DesktopModel, Effects) {
        let (continue_watching_preview, cwp_effects) =
            ContinueWatchingPreview::new(&library, &notifications);
        let (discover, discover_effects) = CatalogWithFilters::<MetaItemPreview>::new(&profile);
        let (library_, library_effects) =
            LibraryWithFilters::<NotRemovedFilter>::new(&library, &notifications);
        let (continue_watching, cw_effects) =
            LibraryWithFilters::<ContinueWatchingFilter>::new(&library, &notifications);
        let (streaming_server, server_effects) = StreamingServer::new::<DesktopEnv>(&profile);
        let model = DesktopModel {
            ctx: Ctx::new(
                profile,
                library,
                streams,
                streaming_server_urls,
                notifications,
                search_history,
                dismissed_events,
            ),
            continue_watching_preview,
            board: Default::default(),
            search: Default::default(),
            discover,
            library: library_,
            continue_watching,
            meta_details: Default::default(),
            streaming_server,
            player: Default::default(),
        };
        (
            model,
            cwp_effects
                .join(discover_effects)
                .join(library_effects)
                .join(cw_effects)
                .join(server_effects),
        )
    }

    /// Serialize one model field to a JSON string for the frontend.
    pub fn get_state_json(&self, field: &DesktopModelField) -> String {
        let result = match field {
            DesktopModelField::Ctx => serde_json::to_string(&self.ctx),
            DesktopModelField::ContinueWatchingPreview => {
                serde_json::to_string(&self.continue_watching_preview)
            }
            DesktopModelField::Board => serde_json::to_string(&self.board),
            DesktopModelField::Search => serde_json::to_string(&self.search),
            DesktopModelField::Discover => serde_json::to_string(&self.discover),
            DesktopModelField::Library => serde_json::to_string(&self.library),
            DesktopModelField::ContinueWatching => serde_json::to_string(&self.continue_watching),
            DesktopModelField::MetaDetails => self.meta_details_json(),
            DesktopModelField::StreamingServer => serde_json::to_string(&self.streaming_server),
            DesktopModelField::Player => serde_json::to_string(&self.player),
        };
        result.unwrap_or_else(|error| format!("{{\"error\":{:?}}}", error.to_string()))
    }

    /// MetaDetails with an extra `watchedVideoIds` array, computed from the `watched` WatchedBitField
    /// (which is `#[serde(skip_serializing)]`), so the frontend can mark watched episodes.
    fn meta_details_json(&self) -> Result<String, serde_json::Error> {
        let mut value = serde_json::to_value(&self.meta_details)?;
        if let (Some(object), Some(watched)) =
            (value.as_object_mut(), self.meta_details.watched.as_ref())
        {
            let watched_ids: Vec<&str> = self
                .meta_details
                .meta_items
                .iter()
                .find_map(|loadable| match &loadable.content {
                    Some(Loadable::Ready(meta)) => Some(meta),
                    _ => None,
                })
                .map(|meta| {
                    meta.videos
                        .iter()
                        .map(|video| video.id.as_str())
                        .filter(|id| watched.get_video(id))
                        .collect()
                })
                .unwrap_or_default();
            object.insert("watchedVideoIds".to_owned(), serde_json::json!(watched_ids));
        }
        serde_json::to_string(&value)
    }
}
