import Foundation

/// Lightweight legacy rails supply only identity, title and poster. Popularity is not a rating,
/// and a poster is not a known landscape backdrop: absent facts/art roles stay absent.
extension TVCinemaCardPresentation {
    static func preview(_ item: MetaPreview) -> Self {
        .init(id: item.id, type: item.type, title: item.name, poster: item.poster)
    }
}
