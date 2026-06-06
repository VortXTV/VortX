//! `TvosModel`, the app model the runtime drives. A trimmed version of `stremio-core-web`'s
//! `WebModel`: a `ctx` field (required by `#[derive(Model)]`) plus one field per screen we render.
//!
//! `#[derive(Model)]` generates `TvosModelField` (a snake_case Serialize/Deserialize enum, one
//! variant per field) and the `update`/`update_field` dispatch. We serialize each field to plain
//! JSON with serde (the engine structs all derive `Serialize`), which Swift decodes with `Codable`.

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

use crate::env::TvosEnv;

#[derive(Model, Clone)]
#[model(TvosEnv)]
pub struct TvosModel {
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

impl TvosModel {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        profile: Profile,
        library: LibraryBucket,
        streams: StreamsBucket,
        streaming_server_urls: ServerUrlsBucket,
        notifications: NotificationsBucket,
        search_history: SearchHistoryBucket,
        dismissed_events: DismissedEventsBucket,
    ) -> (TvosModel, Effects) {
        let (continue_watching_preview, cwp_effects) =
            ContinueWatchingPreview::new(&library, &notifications);
        let (discover, discover_effects) = CatalogWithFilters::<MetaItemPreview>::new(&profile);
        let (library_, library_effects) =
            LibraryWithFilters::<NotRemovedFilter>::new(&library, &notifications);
        let (continue_watching, cw_effects) =
            LibraryWithFilters::<ContinueWatchingFilter>::new(&library, &notifications);
        let (streaming_server, server_effects) = StreamingServer::new::<TvosEnv>(&profile);
        let model = TvosModel {
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

    /// Serialize one model field to a JSON string for the Swift side.
    pub fn get_state_json(&self, field: &TvosModelField) -> String {
        let result = match field {
            TvosModelField::Ctx => serde_json::to_string(&self.ctx),
            TvosModelField::ContinueWatchingPreview => {
                serde_json::to_string(&self.continue_watching_preview)
            }
            TvosModelField::Board => serde_json::to_string(&self.board),
            TvosModelField::Search => serde_json::to_string(&self.search),
            TvosModelField::Discover => serde_json::to_string(&self.discover),
            TvosModelField::Library => serde_json::to_string(&self.library),
            TvosModelField::ContinueWatching => serde_json::to_string(&self.continue_watching),
            TvosModelField::MetaDetails => self.meta_details_json(),
            TvosModelField::StreamingServer => serde_json::to_string(&self.streaming_server),
            TvosModelField::Player => serde_json::to_string(&self.player),
        };
        result.unwrap_or_else(|error| format!("{{\"error\":{:?}}}", error.to_string()))
    }

    /// MetaDetails serialized with an extra `watchedVideoIds` array. The engine's `watched`
    /// WatchedBitField is `#[serde(skip_serializing)]`, so we compute the watched episode ids here
    /// (via `WatchedBitField::get_video`) and inject them for the Swift side to mark episodes.
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
