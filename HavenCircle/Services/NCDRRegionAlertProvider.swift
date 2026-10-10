import Foundation

/// 接 Mac Mini 爬蟲 → Oracle 中繼站的 NCDR 民生示警資料。
/// 只實作 RegionAlertProvider（行政區比對），不做點狀事件：
/// 抽樣過的真實資料裡，CAP 幾乎不附精確經緯度（circle 值缺席機率極高），
/// 套不進「事件點＋半徑」模型，硬套只會得到不精確的定位。
nonisolated struct NCDRRegionAlertProvider: RegionAlertProvider {
    let sourceName = "NCDR 民生示警平台"

    private let endpoint = URL(string: "https://havencircle.looptw.com/crawler/api/latest.php")!

    @concurrent func fetchAlerts() async throws -> [RawRegionAlert] {
        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NCDRProviderError.badResponse
        }

        let envelope = try JSONDecoder().decode(IngestEnvelope.self, from: data)

        return envelope.data.events.compactMap { event in
            // 行政區擷取失敗時（例：道路封閉的「台9線 227k+500」）退而用原文描述——
            // 仍能顯示在提醒中心，只是不參與生活圈比對（不推播）也不畫塗層
            var districts = Self.districts(from: event.areaDesc) ?? []
            if districts.isEmpty, let raw = event.areaDesc?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
                districts = [raw]
            }
            guard !districts.isEmpty else { return nil }
            guard let expires = Self.parseDate(event.expires) else { return nil }
            let ttl = expires.timeIntervalSinceNow
            guard ttl > 0 else { return nil } // 已過期的示警不再收錄，避免一開啟就顯示過期通知

            // 應變建議優先採官方 instruction（官方 API 才有），其次事件描述
            let guidance = (event.instruction?.isEmpty == false ? event.instruction : nil)
                ?? (event.description?.isEmpty == false ? event.description : nil)
                ?? event.headline ?? event.event ?? "請留意官方後續資訊"

            return RawRegionAlert(
                alertKey: "ncdr-\(event.identifier ?? event.feedId ?? UUID().uuidString)",
                title: event.headline ?? event.event ?? "示警",
                kind: event.category ?? event.event ?? "示警",
                affectedDistricts: districts,
                severity: Self.severityText(event.severity),
                guidance: guidance,
                sourceName: event.senderName ?? sourceName,
                sourceURL: "https://alerts.ncdr.nat.gov.tw/",
                ttlSeconds: ttl
            )
        }
    }

    // MARK: - 解析

    /// 從 CAP areaDesc 擷取行政區名稱，去掉縣市前綴，符合生活圈 district 欄位的格式
    /// （例："信義區"，不含"臺北市"）。
    /// 例：「臺中市大雅區三和里」→「大雅區」；「苗栗縣-頭屋鄉」→「頭屋鄉」；
    /// 「臺東縣臺東市豐谷里」→「臺東市」（縣轄市本身就是第二層行政區）。
    static func districts(from areaDesc: String?) -> [String]? {
        guard let areaDesc, !areaDesc.isEmpty else { return nil }
        // 少數示警一次涵蓋多個行政區，用常見分隔符號拆開後逐一解析
        let segments = areaDesc.components(separatedBy: CharacterSet(charactersIn: "、,，"))
        guard let regex = try? NSRegularExpression(pattern: #"^.*?[縣市](.*?[鄉鎮市區])"#) else { return nil }

        var results: [String] = []
        for segment in segments {
            let trimmed = segment.trimmingCharacters(in: .whitespaces)
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, range: range),
                  let captureRange = Range(match.range(at: 1), in: trimmed) else { continue }
            let district = trimmed[captureRange].trimmingCharacters(in: CharacterSet(charactersIn: "-－ "))
            if !district.isEmpty { results.append(district) }
        }
        return results.isEmpty ? nil : results
    }

    static func severityText(_ capSeverity: String?) -> String {
        switch capSeverity {
        case "Extreme": "危急"
        case "Severe": "警戒"
        case "Moderate": "注意"
        case "Minor": "留意"
        default: "提醒"
        }
    }

    /// CAP 時間戳固定帶時區位移（如 +08:00），偶爾含小數秒，兩種格式都要能解
    static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

nonisolated enum NCDRProviderError: Error {
    case badResponse
}

private nonisolated struct IngestEnvelope: Decodable {
    let data: NCDRPayload
}

private nonisolated struct NCDRPayload: Decodable {
    let events: [NCDRCapEvent]
}

private nonisolated struct NCDRCapEvent: Decodable {
    let identifier: String?
    let sender: String?
    let event: String?
    let urgency: String?
    let severity: String?
    let certainty: String?
    let effective: String?
    let expires: String?
    let senderName: String?
    let headline: String?
    let description: String?
    let instruction: String?
    let areaDesc: String?
    let circle: String?
    let polygon: String?
    let category: String?
    let feedId: String?
}
