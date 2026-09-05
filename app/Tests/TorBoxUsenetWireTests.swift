// swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors \
//   app/SourcesShared/TorBoxUsenetWire.swift app/Tests/TorBoxUsenetWireTests.swift -o /tmp/torbox-usenet-wire
import Foundation

@main
private enum TorBoxUsenetWireTests {
    static func main() throws {
        let base = "https://api.torbox.app/v1/api/usenet"
        let key = "fixture+key&value=1/#?"
        let nzb = "https://nzb.example/show.nzb?x=1&y=two%20words"
        guard let create = TorBoxUsenetWire.createRequest(base: base, apiKey: key, nzbURL: nzb,
                                                         boundary: "fixture-boundary") else { fatalError("create") }
        precondition(create.httpMethod == "POST")
        precondition(create.url?.path == "/v1/api/usenet/createusenetdownload")
        precondition(create.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
        precondition(create.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=fixture-boundary")
        let body = String(decoding: create.httpBody!, as: UTF8.self)
        precondition(body == "--fixture-boundary\r\nContent-Disposition: form-data; name=\"link\"\r\n\r\n\(nzb)\r\n"
                     + "--fixture-boundary\r\nContent-Disposition: form-data; name=\"post_processing\"\r\n\r\n-1\r\n"
                     + "--fixture-boundary--\r\n")
        precondition(!body.contains(key))
        precondition(TorBoxUsenetWire.createRequest(base: base, apiKey: key, nzbURL: "bad\r\nfield") == nil)
        let decoder = JSONDecoder()
        for json in [#"{"usenetdownload_id":12345}"#, #"{"usenetdownload_id":"12345"}"#] {
            let result = try decoder.decode(TorBoxUsenetWire.Created.self, from: Data(json.utf8))
            precondition(result.usenetId == 12345)
        }
        for json in [#"{"usenetdownload_id":null}"#, #"{}"#, #"{"usenetdownload_id":-1}"#,
                     #"{"usenetdownload_id":"-1"}"#, #"{"usenetdownload_id":"1.5"}"#,
                     #"{"usenetdownload_id":"99999999999999999999999999"}"#] {
            let result = try decoder.decode(TorBoxUsenetWire.Created.self, from: Data(json.utf8))
            precondition(result.usenetId == nil)
        }
        guard let download = TorBoxUsenetWire.downloadRequest(base: base, apiKey: key, usenetID: 12345, fileID: 678),
              let url = download.url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            fatalError("download")
        }
        precondition(url.path == "/v1/api/usenet/requestdl")
        precondition(download.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
        precondition(parts.queryItems == [URLQueryItem(name: "token", value: key),
                                         URLQueryItem(name: "usenet_id", value: "12345"),
                                         URLQueryItem(name: "file_id", value: "678"),
                                         URLQueryItem(name: "redirect", value: "false")])
        precondition(parts.percentEncodedQuery?.contains("%2B") == true)
        precondition(parts.fragment == nil)
        precondition(TorBoxUsenetWire.downloadRequest(base: base, apiKey: key, usenetID: -1, fileID: 1) == nil)
        print("PASS TorBox Usenet multipart create, string/numeric IDs, escaped query authentication")
    }
}
