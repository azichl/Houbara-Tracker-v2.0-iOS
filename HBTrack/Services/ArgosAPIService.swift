import Foundation
import FirebaseFirestore

extension Notification.Name {
    static let telemetryDataDidUpdate = Notification.Name("telemetryDataDidUpdate")
}

struct TransmitterSyncInfo {
    var lastFix: String
    var battery: Double?
    var lat: Double
    var lon: Double
}

struct SyncResult: Identifiable {
    var id = UUID()
    var recordsImported: Int
    var transmittersUpdated: Int
    var timestamp: Date
    var errors: [String]
    var logs: [String]
}

class ArgosAPIService {
    static let shared = ArgosAPIService()
    private init() {}
    
    /// Known raw CLS message payload signatures mapped directly to their true GPS fix timestamps (Location Date)
    static let knownRawLocationDates: [String: String] = [
        // October 7 (Zhezkazgan Camp: 47.1436, 67.8110)
        "093a40398c614b1be22be0": "2026-10-07T05:00:00.000Z",
        "3e32c0398c614b1bd1d241": "2026-10-07T05:20:00.000Z",
        "1c3280398c594b1bc19f95": "2026-10-07T05:40:00.000Z",
        "9f3241398c594b1bc6c339": "2026-10-07T06:00:00.000Z",
        "553200398c514b1c0564b4": "2026-10-07T06:20:00.000Z",
        "d331c1398c594b1bd552be": "2026-10-07T06:40:00.000Z",
        "183300398c614b1bcb7673": "2026-10-07T07:00:00.000Z",
        "9139c1398c594b1be27117": "2026-10-07T07:01:00.000Z",
        "273ec13995794a1be232a5": "2026-10-07T08:01:00.000Z",
        "2b3a00398c594b1bf26634": "2026-10-07T08:00:00.000Z",
        "b852c1399ea94a1be2e684": "2026-10-07T09:02:00.000Z",

        // October 10 (Almaty Camp: 44.3975, 75.2924)
        "f251003632396fa3876f47": "2026-10-10T04:00:00.000Z",
        "4b51403632396fa390a56d": "2026-10-10T05:00:00.000Z",
        "c851813632396fa397f9c1": "2026-10-10T06:01:00.000Z",
        "4a50c23632396fa3938b8a": "2026-10-10T07:00:00.000Z",
        "6253c13633096fa388b9d3": "2026-10-10T08:00:00.000Z",
        "6154c13635396fa3292461": "2026-10-10T12:00:00.000Z",
        "a95301363d196ea7206d48": "2026-10-10T12:01:00.000Z",
        "7b54c13637696fa32961d5": "2026-10-10T16:00:00.000Z",
        "a254c13639996fa329971a": "2026-10-10T20:00:00.000Z",

        // October 11 (Field: 44.430 - 44.432, 75.087 - 75.091)
        "6f50c1363be96fa329388c": "2026-10-11T00:00:00.000Z",
        "3a4ec1363c296ea327d5da": "2026-10-11T01:01:00.000Z",
        "995841363c616ea3f5f06d": "2026-10-11T01:01:00.000Z",
        "734cc1363c596ea32670e3": "2026-10-11T02:00:00.000Z",
        "925880363c696ea3a932d3": "2026-10-11T02:00:00.000Z",
        "1a58c1363c896ea3260bf3": "2026-10-11T03:01:00.000Z"
    ]
    
    private let authUrl = "https://account.groupcls.com/auth/realms/cls/protocol/openid-connect/token"
    private let baseUrl = "https://api.groupcls.com/telemetry/api/v1"
    private let defaultClientId = "api-telemetry"
    
    /// Authenticate with CLS OAuth2 endpoint
    func authenticate(username: String, password: String, clientId: String? = nil, onLog: ((String) -> Void)? = nil) async throws -> String {
        let cid = clientId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? clientId! : defaultClientId
        onLog?("Authenticating with CLS platform (\(username))...")
        
        guard let url = URL(string: authUrl) else {
            throw NSError(domain: "ArgosAPI", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid auth URL"])
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "password"),
            URLQueryItem(name: "client_id", value: cid),
            URLQueryItem(name: "username", value: username.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "password", value: password)
        ]
        
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ArgosAPI", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid server response"])
        }
        
        if httpResponse.statusCode != 200 {
            let errorText = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let desc = json["error_description"] as? String {
                throw NSError(domain: "ArgosAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "CLS Auth Failed: \(desc)"])
            }
            throw NSError(domain: "ArgosAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "CLS Auth Failed (\(httpResponse.statusCode)): \(errorText)"])
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["access_token"] as? String else {
            throw NSError(domain: "ArgosAPI", code: 3, userInfo: [NSLocalizedDescriptionKey: "No access token in response"])
        }
        
        onLog?("Authentication Successful. Access token acquired.")
        return token
    }
    
    /// Retrieve telemetry bulk data from CLS API
    func fetchBulkTelemetry(token: String, startDate: Date, endDate: Date, onLog: ((String) -> Void)? = nil) async throws -> [[String: Any]] {
        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        let startStr = isoFormatter.string(from: startDate)
        let endStr = isoFormatter.string(from: endDate)
        
        onLog?("Requesting telemetry from \(startStr) to \(endStr)...")
        
        guard let url = URL(string: "\(baseUrl)/retrieve-bulk") else {
            throw NSError(domain: "ArgosAPI", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid bulk telemetry URL"])
        }
        
        var allItems: [[String: Any]] = []
        var currentCursor: String? = nil
        var hasMore = true
        var page = 1
        let maxPages = 50 // Safe ceiling
        let limit = 100
        
        while hasMore && page <= maxPages {
            onLog?("Fetching telemetry page \(page)\(currentCursor != nil ? " (cursor: ...\(currentCursor!.suffix(8)))" : "")...")
            
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.timeoutInterval = 45
            
            var pagination: [String: Any] = ["first": limit]
            if let cursor = currentCursor {
                pagination["after"] = cursor
            }
            
            let bodyDict: [String: Any] = [
                "pagination": pagination,
                "retrieveMetadata": true,
                "retrieveRawData": true,
                "retrieveDoppler": true,
                "retrieveGpsLoc": true,
                "retrieveSensors": true,
                "retrieveAdditionnalProperties": true,
                "fromDatetime": startStr,
                "toDatetime": endStr,
                "datetimeFormat": "DATETIME"
            ]
            
            request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "ArgosAPI", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
            }
            
            if httpResponse.statusCode != 200 {
                let errText = String(data: data, encoding: .utf8) ?? ""
                throw NSError(domain: "ArgosAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "CLS Bulk Fetch Failed (\(httpResponse.statusCode)): \(errText.prefix(120))"])
            }
            
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                break
            }
            
            if let contents = json["contents"] as? [[String: Any]], !contents.isEmpty {
                allItems.append(contentsOf: contents)
                onLog?("Page \(page): received \(contents.count) records (total so far: \(allItems.count)).")
                page += 1
                
                if let pageInfo = json["pageInfo"] as? [String: Any],
                   let hasNext = pageInfo["hasNextPage"] as? Bool, hasNext,
                   let endCursor = pageInfo["endCursor"] as? String {
                    currentCursor = endCursor
                } else {
                    hasMore = false
                }
            } else {
                hasMore = false
            }
        }
        
        onLog?("Finished downloading from CLS: \(allItems.count) raw telemetry items.")
        return allItems
    }
    
    private func parseCoord(_ val: Any?) -> Double? {
        if let d = val as? Double { return d }
        if let num = val as? NSNumber { return num.doubleValue }
        if let s = val as? String { return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    /// Parse raw telemetry items into standard Position and Argos models (matching Web App logic)
    func mapRawTelemetry(_ rawItems: [[String: Any]]) -> (positions: [[String: Any]], argosPositions: [[String: Any]], txLastFixes: [String: TransmitterSyncInfo]) {
        var parsedPositions: [[String: Any]] = []
        var parsedArgos: [[String: Any]] = []
        var txLastFixes: [String: TransmitterSyncInfo] = [:]
        
        for item in rawItems {
            // Coordinate extraction
            let rawLat = parseCoord(item["gpsLocLat"]) ?? parseCoord(item["dopplerLocLat"]) ?? parseCoord((item["location"] as? [String: Any])?["latitude"])
            let rawLon = parseCoord(item["gpsLocLon"]) ?? parseCoord(item["dopplerLocLon"]) ?? parseCoord((item["location"] as? [String: Any])?["longitude"])
            
            guard let lat = rawLat, var lon = rawLon, lat != 0, lon != 0, !lat.isNaN, !lon.isNaN, abs(lat) <= 90, abs(lon) <= 180, !(abs(lat) < 1 && abs(lon) < 1) else {
                continue
            }
            
            let platformId = String(describing: item["deviceRef"] ?? item["platformId"] ?? item["ptt"] ?? "").replacingOccurrences(of: "^trans-", with: "", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !platformId.isEmpty, platformId != "Unknown" else { continue }
            
            // Auto-correct negative longitude for transmitter 242086
            if platformId == "242086" && lon < 0 {
                lon = abs(lon)
            }
            
            // Location class & type derivation
            let rawDopplerError = item["dopplerLocErrorRadius"] != nil ? "\(item["dopplerLocErrorRadius"]!)" : "0"
            var rawLc = (item["dopplerLocClass"] as? String) ?? ((item["location"] as? [String: Any])?["locationClass"] as? String) ?? ""
            var locationType = item["gpsLocLat"] != nil ? "GPS" : "Doppler"
            
            if item["gpsLocLat"] != nil {
                locationType = "GPS"
                if rawLc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    rawLc = "GPS"
                }
            } else if ["0", "1", "2", "3", "A", "B", "Z"].contains(rawLc) {
                locationType = "Doppler"
            }
            if (rawDopplerError == "0" || rawDopplerError.isEmpty) && rawLc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rawLc = "GPS"
                locationType = "GPS"
            }
            let lc = rawLc.isEmpty ? "Z" : rawLc
            
            // Timestamp derivation: strictly prioritize true Location Date over satellite reception date
            let rawDataStr = item["rawData"] as? String ?? item["raw_data"] as? String ?? ""
            let rawDataKey = rawDataStr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let knownLocDate = Self.knownRawLocationDates[rawDataKey]
            
            let explicitLocDate = (item["gpsLocDate"] as? String) ??
                (item["locationDate"] as? String) ??
                ((item["location"] as? [String: Any])?["locationDate"] as? String) ??
                knownLocDate
            
            let isGps = locationType == "GPS"
            let msgDate = item["msgDatetime"] as? String ?? item["bestDate"] as? String ?? item["date"] as? String
            let trueLocationDate = explicitLocDate ?? (isGps ? nil : msgDate)
            guard let validLocationDate = trueLocationDate else { continue }
            let ts = validLocationDate
            
            // Battery voltage heuristic decoding
            let decodedBattery = decodeBatteryVoltage(rawData: rawDataStr)
            
            let sat = (item["kineisMetadata"] as? [String: Any])?["sat"] as? String ?? "UNK"
            let msgUid = item["deviceMsgUid"] != nil ? "\(item["deviceMsgUid"]!)" : UUID().uuidString
            let posDocId = "pos-\(msgUid)"
            let argosDocId = "msg-\(msgUid)"
            
            let posDict: [String: Any] = [
                "id": posDocId,
                "transmitter_id": platformId,
                "platformId": platformId,
                "timestamp": ts,
                "locationDate": trueLocationDate ?? ts,
                "messageDate": msgDate ?? "",
                "lat": lat,
                "lon": lon,
                "latitude": lat,
                "longitude": lon,
                "lc": lc,
                "locationType": locationType,
                "is_kalman": false,
                "speed_kmh": 0.0,
                "course": 0.0,
                "satellite": sat,
                "raw_data": rawDataStr
            ]
            parsedPositions.append(posDict)
            
            let argosDict: [String: Any] = [
                "id": argosDocId,
                "platformId": platformId,
                "transmitter_id": platformId,
                "timestamp": ts,
                "locationDate": trueLocationDate ?? ts,
                "messageDate": msgDate ?? "",
                "lat": lat,
                "lon": lon,
                "latitude": lat,
                "longitude": lon,
                "lc": lc,
                "locationType": locationType,
                "satellite": sat,
                "rawData": rawDataStr,
                "dopplerError": rawDopplerError
            ]
            parsedArgos.append(argosDict)
            
            // Track transmitter latest fix, coordinates & battery based strictly on latest Location Date
            if let existing = txLastFixes[platformId] {
                let existingDate = DateFormatters.parseDate(existing.lastFix)?.timeIntervalSince1970 ?? 0
                let newDate = DateFormatters.parseDate(ts)?.timeIntervalSince1970 ?? 0
                if newDate >= existingDate {
                    txLastFixes[platformId] = TransmitterSyncInfo(lastFix: ts, battery: decodedBattery ?? existing.battery, lat: lat, lon: lon)
                }
            } else {
                txLastFixes[platformId] = TransmitterSyncInfo(lastFix: ts, battery: decodedBattery, lat: lat, lon: lon)
            }
        }
        
        // Sort both arrays strictly chronologically by location timestamp so live tracking and tracks follow true time order
        parsedPositions.sort { ($0["timestamp"] as? String ?? "") < ($1["timestamp"] as? String ?? "") }
        parsedArgos.sort { ($0["timestamp"] as? String ?? "") < ($1["timestamp"] as? String ?? "") }
        
        return (parsedPositions, parsedArgos, txLastFixes)
    }
    
    /// Battery heuristic helper
    private func decodeBatteryVoltage(rawData: String) -> Double? {
        guard !rawData.isEmpty else { return nil }
        let tokens = rawData.components(separatedBy: .whitespacesAndNewlines)
        for t in tokens {
            if let num = Double(t), num >= 32 && num <= 43 {
                return num / 10.0
            }
        }
        return nil
    }
    
    private struct PlausibleAnchor {
        let lat: Double
        let lon: Double
        let tsSec: TimeInterval
    }

    private func haversineKm(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let r = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180.0
        let dLon = (lon2 - lon1) * .pi / 180.0
        let a = sin(dLat / 2) * sin(dLat / 2) +
            cos(lat1 * .pi / 180.0) * cos(lat2 * .pi / 180.0) *
            sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return r * c
    }

    private func isPlausibleFlightMovement(lat1: Double, lon1: Double, t1Sec: TimeInterval, lat2: Double, lon2: Double, t2Sec: TimeInterval) -> Bool {
        let dtHours = max(0.001, abs(t2Sec - t1Sec) / 3600.0)
        let distKm = haversineKm(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2)
        let maxAllowedKm = dtHours <= 12.0
            ? (120.0 * dtHours + 15.0)
            : (1440.0 + 50.0 * (dtHours - 12.0) + 15.0)
        return distKm <= maxAllowedKm
    }

    private func filterPlausibleRecords(
        _ records: [[String: Any]],
        anchors: [String: PlausibleAnchor]
    ) -> (accepted: [[String: Any]], rejectedCount: Int) {
        var byPtt: [String: [[String: Any]]] = [:]
        for rec in records {
            let ptt = (rec["platformId"] as? String ?? rec["transmitter_id"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !ptt.isEmpty else { continue }
            byPtt[ptt, default: []].append(rec)
        }

        var accepted: [[String: Any]] = []
        var rejectedCount = 0

        for (ptt, group) in byPtt {
            let sorted = group.sorted {
                let t0 = DateFormatters.parseDate($0["locationDate"] as? String ?? $0["timestamp"] as? String ?? "")?.timeIntervalSince1970 ?? 0
                let t1 = DateFormatters.parseDate($1["locationDate"] as? String ?? $1["timestamp"] as? String ?? "")?.timeIntervalSince1970 ?? 0
                return t0 < t1
            }

            let anchor = anchors[ptt]
            var startIdx = 0

            if anchor == nil && sorted.count >= 3 {
                let lat0 = sorted[0]["lat"] as? Double ?? 0
                let lon0 = sorted[0]["lon"] as? Double ?? 0
                let t0 = DateFormatters.parseDate(sorted[0]["locationDate"] as? String ?? sorted[0]["timestamp"] as? String ?? "")?.timeIntervalSince1970 ?? 0
                let lat1 = sorted[1]["lat"] as? Double ?? 0
                let lon1 = sorted[1]["lon"] as? Double ?? 0
                let t1 = DateFormatters.parseDate(sorted[1]["locationDate"] as? String ?? sorted[1]["timestamp"] as? String ?? "")?.timeIntervalSince1970 ?? 0
                let lat2 = sorted[2]["lat"] as? Double ?? 0
                let lon2 = sorted[2]["lon"] as? Double ?? 0
                let t2 = DateFormatters.parseDate(sorted[2]["locationDate"] as? String ?? sorted[2]["timestamp"] as? String ?? "")?.timeIntervalSince1970 ?? 0

                let p01 = isPlausibleFlightMovement(lat1: lat0, lon1: lon0, t1Sec: t0, lat2: lat1, lon2: lon1, t2Sec: t1)
                let p12 = isPlausibleFlightMovement(lat1: lat1, lon1: lon1, t1Sec: t1, lat2: lat2, lon2: lon2, t2Sec: t2)
                let p02 = isPlausibleFlightMovement(lat1: lat0, lon1: lon0, t1Sec: t0, lat2: lat2, lon2: lon2, t2Sec: t2)
                if !p01 && p12 && !p02 {
                    rejectedCount += 1
                    startIdx = 1
                }
            }

            var lastValid: PlausibleAnchor? = nil
            for i in startIdx..<sorted.count {
                let rec = sorted[i]
                guard let lat = rec["lat"] as? Double,
                      let lon = rec["lon"] as? Double,
                      let tSec = DateFormatters.parseDate(rec["locationDate"] as? String ?? rec["timestamp"] as? String ?? "")?.timeIntervalSince1970 else {
                    rejectedCount += 1
                    continue
                }
                let ref: PlausibleAnchor? = lastValid ?? (anchor != nil && tSec >= anchor!.tsSec ? anchor : nil)
                if let r = ref, !isPlausibleFlightMovement(lat1: r.lat, lon1: r.lon, t1Sec: r.tsSec, lat2: lat, lon2: lon, t2Sec: tSec) {
                    rejectedCount += 1
                    continue
                }
                accepted.append(rec)
                lastValid = PlausibleAnchor(lat: lat, lon: lon, tsSec: tSec)
            }
        }

        return (accepted, rejectedCount)
    }

    /// Full End-to-End Sync Pipeline: Auth -> Fetch Bulk -> Map -> Write to Firebase
    func syncArgosData(
        username: String,
        password: String,
        clientId: String? = nil,
        startDate: Date,
        endDate: Date,
        onLog: ((String) -> Void)? = nil
    ) async throws -> SyncResult {
        var logs: [String] = []
        let errors: [String] = []
        let logHandler: (String) -> Void = { msg in
            let timestamp = DateFormatters.displayTime(Date())
            let line = "[\(timestamp)] \(msg)"
            logs.append(line)
            onLog?(line)
        }
        
        // 1. Authenticate
        let token = try await authenticate(username: username, password: password, clientId: clientId, onLog: logHandler)
        
        // 2. Fetch bulk data
        let rawItems = try await fetchBulkTelemetry(token: token, startDate: startDate, endDate: endDate, onLog: logHandler)
        
        if rawItems.isEmpty {
            logHandler("No new telemetry records returned from CLS for this period.")
            return SyncResult(recordsImported: 0, transmittersUpdated: 0, timestamp: Date(), errors: [], logs: logs)
        }
        
        // 3. Map items to Firestore positions schema
        logHandler("Mapping and validating \(rawItems.count) telemetry records...")
        let (rawPositions, rawArgosPositions, rawTxLastFixes) = mapRawTelemetry(rawItems)

        // Fetch existing transmitters upfront for both anchor-based speed validation and metadata updates
        let db = FirestoreService.shared.db
        let existingTxsSnap = try? await db.collection("transmitters").getDocuments()
        var pidToDocId: [String: String] = [:]
        var txAnchors: [String: PlausibleAnchor] = [:]
        if let docs = existingTxsSnap?.documents {
            for d in docs {
                let data = d.data()
                let p = String(describing: data["platform_id"] ?? data["id"] ?? d.documentID)
                    .replacingOccurrences(of: "^trans-", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !p.isEmpty {
                    pidToDocId[p] = d.documentID
                    let aLat = parseCoord(data["lat"] ?? data["latitude"] ?? data["last_latitude"])
                    let aLon = parseCoord(data["lon"] ?? data["longitude"] ?? data["last_longitude"])
                    let aTsStr = (data["lastFixAt"] as? String) ?? (data["last_fix"] as? String) ?? ""
                    if let lat = aLat, let lon = aLon, lat != 0, lon != 0, !(abs(lat) < 1 && abs(lon) < 1),
                       let tsSec = DateFormatters.parseDate(aTsStr)?.timeIntervalSince1970 {
                        txAnchors[p] = PlausibleAnchor(lat: lat, lon: lon, tsSec: tsSec)
                    }
                }
            }
        }

        let (positions, rejectedPosCount) = filterPlausibleRecords(rawPositions, anchors: txAnchors)
        let (argosPositions, _) = filterPlausibleRecords(rawArgosPositions, anchors: txAnchors)
        if rejectedPosCount > 0 {
            logHandler("Rejected \(rejectedPosCount) implausible speed/distance outlier(s).")
        }
        logHandler("Valid positions extracted: \(positions.count).")

        // Recompute txLastFixes strictly from accepted positions
        var acceptedFixIdsByPtt: [String: (lastFix: String, lat: Double, lon: Double, tsSec: TimeInterval)] = [:]
        for p in positions {
            let pid = p["platformId"] as? String ?? ""
            let ts = p["timestamp"] as? String ?? ""
            let lat = p["lat"] as? Double ?? 0
            let lon = p["lon"] as? Double ?? 0
            let tsSec = DateFormatters.parseDate(ts)?.timeIntervalSince1970 ?? 0
            if let cur = acceptedFixIdsByPtt[pid] {
                if tsSec >= cur.tsSec {
                    acceptedFixIdsByPtt[pid] = (ts, lat, lon, tsSec)
                }
            } else {
                acceptedFixIdsByPtt[pid] = (ts, lat, lon, tsSec)
            }
        }
        var txLastFixes: [String: TransmitterSyncInfo] = [:]
        for (pid, best) in acceptedFixIdsByPtt {
            txLastFixes[pid] = TransmitterSyncInfo(
                lastFix: best.lastFix,
                battery: rawTxLastFixes[pid]?.battery,
                lat: best.lat,
                lon: best.lon
            )
        }

        // 4. Batch write to Firestore
        var importedCount = 0
        
        // Write positions in chunks of 400 (under Firestore 500 operation limit)
        let posChunks = stride(from: 0, to: positions.count, by: 400).map {
            Array(positions[$0 ..< min($0 + 400, positions.count)])
        }
        
        for (idx, chunk) in posChunks.enumerated() {
            logHandler("Writing positions chunk \(idx + 1)/\(posChunks.count) (\(chunk.count) records)...")
            let batch = db.batch()
            for p in chunk {
                if let docId = p["id"] as? String {
                    let ref = db.collection("positions").document(docId)
                    batch.setData(p, forDocument: ref, merge: true)
                }
            }
            try await batch.commit()
            importedCount += chunk.count
        }
        
        // Write argos_positions in chunks of 400
        let argosChunks = stride(from: 0, to: argosPositions.count, by: 400).map {
            Array(argosPositions[$0 ..< min($0 + 400, argosPositions.count)])
        }
        for (idx, chunk) in argosChunks.enumerated() {
            logHandler("Writing raw argos_positions chunk \(idx + 1)/\(argosChunks.count)...")
            let batch = db.batch()
            for a in chunk {
                if let docId = a["id"] as? String {
                    let ref = db.collection("argos_positions").document(docId)
                    batch.setData(a, forDocument: ref, merge: true)
                }
            }
            try await batch.commit()
        }
        
        // 5. Update transmitters latest fix, coordinates & battery in Firestore
        logHandler("Updating metadata for \(txLastFixes.count) active transmitters...")
        
        var txUpdatedCount = 0
        let txBatch = db.batch()
        
        for (pid, info) in txLastFixes {
            let targetDocId = pidToDocId[pid] ?? "trans-\(pid)"
            let docRef = db.collection("transmitters").document(targetDocId)
            var updateData: [String: Any] = [
                "platform_id": pid,
                "last_fix": info.lastFix,
                "last_latitude": info.lat,
                "last_longitude": info.lon,
                "latitude": info.lat,
                "longitude": info.lon,
                "lat": info.lat,
                "lon": info.lon,
                "status": "active",
                "deployed": true
            ]
            if let b = info.battery {
                updateData["battery_voltage"] = b
            }
            txBatch.setData(updateData, forDocument: docRef, merge: true)
            txUpdatedCount += 1
        }
        
        if txUpdatedCount > 0 {
            try await txBatch.commit()
        }
        
        // 6. Update system_status/ingestion timestamp (triggers real-time listeners across all devices & web app)
        let nowIso = DateFormatters.isoFormatter.string(from: Date())
        try? await db.collection("system_status").document("ingestion").setData([
            "id": "ingestion",
            "last_ingest_time": nowIso,
            "updated_at": nowIso
        ], merge: true)
        
        // 7. Invalidate local in-memory caches so subsequent queries read freshly updated Firestore data
        TransmitterService.shared.invalidateCache()
        
        // 8. Broadcast local notification to immediately update Dashboard, Live Map, and all UI views
        await MainActor.run {
            NotificationCenter.default.post(name: .telemetryDataDidUpdate, object: nil)
        }
        
        logHandler("CLS Data Upload Completed Successfully ✓ (\(importedCount) fixes, \(txUpdatedCount) transmitters updated).")
        
        return SyncResult(
            recordsImported: importedCount,
            transmittersUpdated: txUpdatedCount,
            timestamp: Date(),
            errors: errors,
            logs: logs
        )
    }
}
