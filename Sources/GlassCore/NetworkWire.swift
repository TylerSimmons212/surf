import Foundation

public enum NetworkWire {

    public static func decodeRequests(_ value: Any?) -> [NetworkRequest] {
        guard let raw = value as? [[String: Any]] else { return [] }
        return raw.compactMap(decodeRequest)
    }

    public static func decodeRequest(_ value: Any?) -> NetworkRequest? {
        guard let dict = value as? [String: Any],
              let id = dict["id"] as? String,
              let url = dict["url"] as? String
        else { return nil }

        let mime = (dict["responseHeaders"] as? [String: String])?
            .first { $0.key.lowercased() == "content-type" }?.value ?? ""

        return NetworkRequest(
            id: id,
            url: url,
            method: dict["method"] as? String ?? "GET",
            kind: NetworkKind.from(
                initiator: dict["initiator"] as? String ?? "",
                mime: mime,
                url: url
            ),
            // Absent means no status is available, which is different from
            // zero — every non-fetch resource lands here.
            status: dict["status"] as? Int,
            statusText: dict["statusText"] as? String ?? "",
            failure: dict["failure"] as? String,
            // Same distinction: absent is "not allowed to know", not "empty".
            transferSize: dict["transferSize"] as? Int,
            bodySize: dict["bodySize"] as? Int,
            startedAt: dict["startedAt"] as? Double ?? 0,
            duration: dict["duration"] as? Double,
            isFromCache: dict["isFromCache"] as? Bool ?? false,
            isOpaque: dict["isOpaque"] as? Bool ?? false,
            protocolName: dict["protocolName"] as? String ?? "",
            initiator: dict["initiator"] as? String ?? "",
            requestHeaders: dict["requestHeaders"] as? [String: String] ?? [:],
            responseHeaders: dict["responseHeaders"] as? [String: String] ?? [:],
            isDetailed: dict["detailed"] as? Bool ?? false,
            hasRequestBody: dict["hasRequestBody"] as? Bool ?? false,
            hasResponseBody: dict["hasResponseBody"] as? Bool ?? false
        )
    }

    /// One request's bodies, fetched on demand.
    public static func decodeBodies(
        _ body: [String: Any]
    ) -> (request: NetworkBody?, response: NetworkBody?) {
        func read(_ prefix: String) -> NetworkBody? {
            let omission = (body["\(prefix)Omission"] as? String).flatMap(BodyOmission.init)
            guard let text = body[prefix] as? String else {
                // No text and no reason means the request simply had no body —
                // a GET with nothing to send is not an omission.
                guard let omission else { return nil }
                return NetworkBody(omission: omission)
            }
            return NetworkBody(
                text: text,
                byteCount: body["\(prefix)Bytes"] as? Int ?? text.utf8.count,
                isTruncated: body["\(prefix)Truncated"] as? Bool ?? false,
                contentType: body["\(prefix)Type"] as? String ?? "",
                omission: omission
            )
        }
        return (read("requestBody"), read("responseBody"))
    }

    /// Whether a record came from Resource Timing, and so must be folded into a
    /// patched record rather than listed alongside it.
    public static func isTiming(_ value: Any?) -> Bool {
        (value as? [String: Any])?["timing"] as? Bool ?? false
    }

    /// Splits a batch into the records that stand alone and the timing
    /// observations that have to be merged.
    public static func decodeBatch(
        _ value: Any?
    ) -> (records: [NetworkRequest], timings: [NetworkRequest]) {
        guard let raw = value as? [[String: Any]] else { return ([], []) }
        var records: [NetworkRequest] = []
        var timings: [NetworkRequest] = []
        for entry in raw {
            guard let request = decodeRequest(entry) else { continue }
            if isTiming(entry) { timings.append(request) } else { records.append(request) }
        }
        return (records, timings)
    }
}
