import CoreLocation
import Foundation

/// 台中市消防局「即時災情」火災來源。
///
/// 官方公開頁面提供 119 受理時間、案別、行政區與處理狀態。為避免收集或顯示
/// 不必要的精確位置，App 只使用行政區中心與 3 公里精度，不帶入街道地址。
nonisolated struct TaichungFireEventProvider: EventProvider {
    let sourceName = "台中市消防局即時災情"

    private let endpoint = URL(
        string: "https://havencircle.looptw.com/crawler/api/latest.php?dataset=taichung_fire"
    )!
    private static let sourceURL =
        "https://www.fire.taichung.gov.tw/caselist/index.asp?Parser=99,8,226"
    private static let ongoingTTL: TimeInterval = 6 * 3_600
    private static let resolvedTTL: TimeInterval = 60 * 60

    @concurrent func fetchReports() async throws -> [RawEventReport] {
        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw NCDRProviderError.badResponse
        }

        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return envelope.data.events.compactMap { event in
            guard let occurredAt = Self.dateFormatter.date(from: event.acceptedAt),
                  let coordinate = NewsEventProvider.locate(
                    county: "台中市",
                    district: event.district
                  ) else {
                return nil
            }

            let isResolved = event.status.contains("返隊")
                || event.status.contains("結束")
                || event.status.contains("解除")
            let ttl = isResolved ? Self.resolvedTTL : Self.ongoingTTL
            let remaining = occurredAt.addingTimeInterval(ttl).timeIntervalSinceNow
            guard remaining > 0 else { return nil }

            let subtype = event.caseSub.isEmpty ? "火災" : event.caseSub
            let district = event.district.isEmpty ? "台中市" : "台中市\(event.district)"
            return RawEventReport(
                title: "\(district)\(subtype)火災通報",
                eventType: EventCategory.fire,
                approximateLocation: district,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                precisionMeters: 3_000,
                sourceName: sourceName,
                sourceURL: Self.sourceURL,
                isOfficial: true,
                occurredAt: occurredAt,
                ttlSeconds: remaining,
                detail: isResolved
                    ? "台中市消防局公開派遣資訊顯示案件已結束處理。"
                    : "台中市消防局已受理火災案件，請避開周邊並留意官方後續資訊。",
                stableDeduplicationKey:
                    "taichung-fire-\(event.acceptedAt)-\(event.district)-\(event.caseSub)"
            )
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Taipei")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter
    }()
}

private nonisolated struct Envelope: Decodable {
    let data: Payload

    struct Payload: Decodable {
        let events: [Record]
    }

    struct Record: Decodable {
        let acceptedAt: String
        let caseSub: String
        let status: String
        let district: String
    }
}
