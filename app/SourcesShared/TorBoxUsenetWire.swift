import Foundation

/// TorBox's Usenet endpoints have different wire contracts from ordinary JSON debrid requests.
/// Keep credential-bearing requests internal; callers expose only the validated CDN response URL.
enum TorBoxUsenetWire {
    struct Created: Decodable {
        let usenetId: Int?
        enum CodingKeys: String, CodingKey { case usenetId = "usenetdownload_id" }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let value = try? values.decode(Int.self, forKey: .usenetId) {
                usenetId = value >= 0 ? value : nil
            } else if let value = try? values.decode(String.self, forKey: .usenetId),
                      !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
                      let number = Int(value) {
                usenetId = number
            } else {
                usenetId = nil
            }
        }
    }

    static func createRequest(base: String, apiKey: String, nzbURL: String,
                              boundary: String = "vortx-\(UUID().uuidString)") -> URLRequest? {
        guard let url = URL(string: "\(base)/createusenetdownload"),
              !boundary.isEmpty, !boundary.utf8.contains(13), !boundary.utf8.contains(10),
              !nzbURL.utf8.contains(13), !nzbURL.utf8.contains(10) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let body = "--\(boundary)\r\nContent-Disposition: form-data; name=\"link\"\r\n\r\n\(nzbURL)\r\n"
            + "--\(boundary)\r\nContent-Disposition: form-data; name=\"post_processing\"\r\n\r\n-1\r\n"
            + "--\(boundary)--\r\n"
        request.httpBody = Data(body.utf8)
        return request
    }

    static func downloadRequest(base: String, apiKey: String, usenetID: Int, fileID: Int) -> URLRequest? {
        guard usenetID >= 0, fileID >= 0,
              var components = URLComponents(string: "\(base)/requestdl") else { return nil }
        // This endpoint documents query-token authentication. The secret is never returned to the player.
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard let token = apiKey.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        components.percentEncodedQuery = "token=\(token)&usenet_id=\(usenetID)&file_id=\(fileID)&redirect=false"
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }
}
