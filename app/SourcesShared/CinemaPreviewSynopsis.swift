import Foundation

/// A preview owns its lookup; it must never replace the detail/player metadata slot.
enum CinemaPreviewSynopsis {
    private struct Envelope: Decodable {
        let meta: Metadata?
    }
    private struct Metadata: Decodable {
        let id: String
        let type: String?
        let description: String?
    }

    static func description(in data: Data, id: String, type: String) -> String? {
        guard data.count <= 2 * 1024 * 1024,
              let meta = try? JSONDecoder().decode(Envelope.self, from: data).meta,
              meta.id == id,
              meta.type == nil || meta.type == type else { return nil }
        let text = meta.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    static func load(urls: [URL], id: String, type: String) async -> String? {
        // At most three independent six-second requests. Closing/replacing the preview cancels them.
        await withTaskGroup(of: String?.self) { group in
            for url in urls.prefix(3) {
                group.addTask {
                    guard !Task.isCancelled else { return nil }
                    var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 6)
                    request.setValue("application/json", forHTTPHeaderField: "Accept")
                    do {
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard !Task.isCancelled,
                              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                        return description(in: data, id: id, type: type)
                    } catch { return nil }
                }
            }
            for await value in group {
                if let value {
                    group.cancelAll()
                    return value
                }
            }
            return nil
        }
    }
}
