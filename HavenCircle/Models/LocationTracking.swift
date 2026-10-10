import Foundation
import CoreLocation

// 背景定位／軌跡／守護地點偵測用的純函式與小型值型別。
// 刻意不碰 CLLocationManager、Firestore、SwiftData，讓判斷邏輯可以在 Preview／自我檢查中重現。

/// 一筆定位取樣（只留判斷所需的欄位）
struct LocationSample: Equatable {
    let time: Date
    let latitude: Double
    let longitude: Double
    /// 水平定位精度（公尺）；負值＝未知
    let accuracy: Double
    /// 瞬時速度（公尺／秒）；負值＝系統沒給（基地台定位、剛開始定位時常見）
    let speed: Double

    init(time: Date, latitude: Double, longitude: Double, accuracy: Double = -1, speed: Double = -1) {
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.speed = speed
    }

    init(_ location: CLLocation) {
        self.init(
            time: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracy: location.horizontalAccuracy,
            speed: location.speed
        )
    }

    func distance(to other: LocationSample) -> Double {
        CLLocation(latitude: latitude, longitude: longitude)
            .distance(from: CLLocation(latitude: other.latitude, longitude: other.longitude))
    }
}

// MARK: - 移動判定（共用：靜止偵測與上傳端的「開始停留時間」）

/// 「這筆定位算不算真的移動」。GPS 在室內／桌上也會漂移數十到上百公尺，單看位移會把靜止誤判成移動，所以：
/// - 位移必須大於「定位精度」與 50 公尺兩者較大值（精度差時漂移本來就大）；
/// - 系統給了速度且 <= 1 公尺／秒，視為漂移（除非是遠距離跳點）；速度未知（負值）時只看位移；
/// - 必須連續 2 筆都符合才確認移動；單筆極大跳點（> max(500 公尺, 3 倍精度)）例外，視為確實換了地方。
enum MovementJudge {
    static let minDisplacement: Double = 50
    static let movingSpeed: Double = 1.0
    static let confirmCount = 2
    static let definiteJumpFloor: Double = 500

    static func threshold(accuracy: Double) -> Double { max(minDisplacement, max(0, accuracy)) }

    /// 單筆：與基準點相距 displacement、精度 accuracy、速度 speed，是否像在移動
    static func isMovedSample(displacement: Double, accuracy: Double, speed: Double) -> Bool {
        guard displacement > threshold(accuracy: accuracy) else { return false }
        if speed >= 0, speed <= movingSpeed {
            return isDefiniteJump(displacement: displacement, accuracy: accuracy)
        }
        return true
    }

    static func isDefiniteJump(displacement: Double, accuracy: Double) -> Bool {
        displacement > max(definiteJumpFloor, 3 * max(0, accuracy))
    }

    /// 餵入單筆判斷結果與目前連續次數，回傳「是否確認移動」與新的連續次數
    static func advance(
        isMovedSample: Bool, displacement: Double, accuracy: Double, streak: Int
    ) -> (confirmed: Bool, streak: Int) {
        guard isMovedSample else { return (false, 0) }
        let next = streak + 1
        return (next >= confirmCount || isDefiniteJump(displacement: displacement, accuracy: accuracy), next)
    }
}

// MARK: - 靜止偵測

enum MotionState: String, Equatable {
    case moving
    case stationary
}

/// 靜止／移動偵測（純狀態機）。
///
/// 規則：
/// - 移動中 → 靜止：往前找「至少 [stationaryWindow]（4 分鐘）以前」的最後一筆取樣當基準，
///   基準與其後所有取樣都在 [stationaryRadius]（50 公尺）內，才判定靜止。
///   （靜止時 distanceFilter 放大、定位很少回呼，所以允許用心跳那一筆跟 4 分鐘前的取樣比。）
/// - 靜止 → 移動：離開靜止錨點的位移大於 max(定位精度, 50 公尺)、速度不是明確的低速，
///   且連續 2 筆（見 [MovementJudge]），避免 GPS 漂移造成來回切換。
struct MotionDetector {
    static let stationaryWindow: TimeInterval = 4 * 60
    static let stationaryRadius: Double = 50
    /// 緩衝只保留這麼久的取樣，避免無限成長
    private static let retention: TimeInterval = 15 * 60

    private(set) var state: MotionState = .moving
    private var samples: [LocationSample] = []
    private var stationaryAnchor: LocationSample?
    /// 靜止中連續「像在移動」的筆數
    private var movedStreak = 0

    init() {}

    /// 餵一筆新定位，回傳目前狀態
    @discardableResult
    mutating func ingest(_ sample: LocationSample) -> MotionState {
        samples.append(sample)
        samples.removeAll { $0.time < sample.time.addingTimeInterval(-Self.retention) }

        switch state {
        case .moving:
            let cutoff = sample.time.addingTimeInterval(-Self.stationaryWindow)
            guard let baseIndex = samples.lastIndex(where: { $0.time <= cutoff }) else { return state }
            let span = samples[baseIndex...]
            // 精度差時漂移本來就大：靜止半徑隨精度放寬
            let radius = max(Self.stationaryRadius, sample.accuracy)
            if span.allSatisfy({ $0.distance(to: sample) < radius }) {
                state = .stationary
                stationaryAnchor = sample
                movedStreak = 0
            }
        case .stationary:
            if let anchor = stationaryAnchor {
                let displacement = anchor.distance(to: sample)
                let moved = MovementJudge.isMovedSample(
                    displacement: displacement, accuracy: sample.accuracy, speed: sample.speed
                )
                let result = MovementJudge.advance(
                    isMovedSample: moved, displacement: displacement,
                    accuracy: sample.accuracy, streak: movedStreak
                )
                movedStreak = result.streak
                if result.confirmed {
                    state = .moving
                    stationaryAnchor = nil
                    movedStreak = 0
                    samples = [sample]
                }
            }
        }
        return state
    }

    mutating func reset() {
        state = .moving
        samples = []
        stationaryAnchor = nil
        movedStreak = 0
    }
}

/// 兩種定位參數組合（移動中 vs 靜止省電）
struct LocationProfile: Equatable {
    let desiredAccuracy: CLLocationAccuracy
    let distanceFilter: CLLocationDistance

    static let moving = LocationProfile(desiredAccuracy: kCLLocationAccuracyHundredMeters, distanceFilter: 50)
    /// 靜止：精度維持 100 公尺（1 公里精度的定位很少回呼、上傳端還會因精度 > 1000 公尺拒收），
    /// 且不設距離門檻——讓系統持續有定位回呼喚醒 App，回呼端（LocationService）再節流成每 5 分鐘一筆心跳
    static let stationary = LocationProfile(desiredAccuracy: kCLLocationAccuracyHundredMeters, distanceFilter: kCLDistanceFilterNone)

    static func profile(for state: MotionState) -> LocationProfile {
        state == .moving ? .moving : .stationary
    }
}

// MARK: - 上傳節流

enum UploadThrottle {
    /// 最短間隔：30 秒一筆
    static let minInterval: TimeInterval = 30
    /// 位移超過這個距離就不受最短間隔限制
    static let bigMoveMeters: Double = 200

    static func shouldUpload(previous: LocationSample?, current: LocationSample) -> Bool {
        guard let previous else { return true }
        if current.distance(to: previous) > bigMoveMeters { return true }
        return current.time.timeIntervalSince(previous.time) >= minInterval
    }
}

// MARK: - 24 小時軌跡

enum TrailPolicy {
    /// 軌跡與到達／離開事件保留 24 小時
    static let retention: TimeInterval = 24 * 60 * 60
    /// 每次最多刪幾筆過期點
    static let cleanupBatchLimit = 50
    /// 清理查詢最短間隔（每次上傳都查會白白多讀文件；10 分鐘一次足以讓過期點不累積）
    static let cleanupMinInterval: TimeInterval = 10 * 60
    /// 軌跡點最短間隔（靜止時不用每次上傳都加點）
    static let appendMinInterval: TimeInterval = 10 * 60
    /// 位移超過這個距離就一定追加軌跡點
    static let appendMinMoveMeters: Double = 30

    static func cutoff(now: Date = .now) -> Date { now.addingTimeInterval(-retention) }

    /// 寫入時就帶上的 Firestore TTL 欄位 expireAt
    static func expireAt(for pointTime: Date) -> Date { pointTime.addingTimeInterval(retention) }

    static func isWithinWindow(_ date: Date, now: Date = .now) -> Bool { date >= cutoff(now: now) }

    static func shouldCleanup(lastCleanupAt: Date?, now: Date = .now) -> Bool {
        guard let lastCleanupAt else { return true }
        return now.timeIntervalSince(lastCleanupAt) >= cleanupMinInterval
    }

    static func shouldAppendPoint(previous: LocationSample?, current: LocationSample) -> Bool {
        guard let previous else { return true }
        if current.distance(to: previous) >= appendMinMoveMeters { return true }
        return current.time.timeIntervalSince(previous.time) >= appendMinInterval
    }

    /// 軌跡總長度（公尺），列表摘要用
    static func totalDistance(_ points: [LocationSample]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { $0 + $1.0.distance(to: $1.1) }
    }
}

/// 軌跡點（Firestore: families/{id}/locations/{uid}/trail/{autoId}）
struct TrailPoint: Identifiable, Equatable {
    let id: String
    let sample: LocationSample
    let accuracy: Double
}

// MARK: - 守護地點地理圍欄

struct GeofencePlace: Equatable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
}

enum GeofencePlanner {
    /// iOS 單一 App 最多監控 20 個區域
    static let systemLimit = 20
    /// 到達／離開判斷用的圍欄半徑。固定圈的 radiusMeters 是「警戒半徑」（500 公尺到 5 公里），
    /// 拿來當到家偵測會太粗，所以另用較小的固定半徑。
    static let regionRadiusMeters: Double = 150
    static let identifierPrefix = "hc-place-"

    static func identifier(forCircleKey key: String) -> String { identifierPrefix + key }

    /// 超過 20 個時取離目前位置最近的 20 個；不知道目前位置就維持原順序取前 20 個
    static func select(
        _ places: [GeofencePlace],
        near center: (latitude: Double, longitude: Double)?,
        limit: Int = systemLimit
    ) -> [GeofencePlace] {
        guard places.count > limit else { return places }
        guard let center else { return Array(places.prefix(limit)) }
        let origin = CLLocation(latitude: center.latitude, longitude: center.longitude)
        return places
            .sorted {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude).distance(from: origin)
                    < CLLocation(latitude: $1.latitude, longitude: $1.longitude).distance(from: origin)
            }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - 共用守護地點去重

/// 去重用的最小地點資料
struct PlaceCandidate: Equatable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
}

/// 兩台裝置各自建了同名地點時，雲端會出現兩筆：同名（忽略空白與大小寫）且相距 < 150 公尺視為同一個地點。
enum PlaceDedup {
    static let radiusMeters: Double = 150

    static func normalized(_ name: String) -> String {
        name.filter { !$0.isWhitespace }.lowercased()
    }

    static func isSame(_ a: PlaceCandidate, _ b: PlaceCandidate) -> Bool {
        guard normalized(a.name) == normalized(b.name) else { return false }
        return CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude)) < radiusMeters
    }

    static func match(_ place: PlaceCandidate, in list: [PlaceCandidate]) -> PlaceCandidate? {
        list.first { $0.id != place.id && isSame($0, place) }
    }

    /// 把重複的歸成一組：每組保留 id 最小的（所有裝置算出同一個結果，不會各自挑不同的而互相打架）。
    /// mapping：被收掉的 id → 保留的 id
    static func collapse(_ list: [PlaceCandidate]) -> (kept: [PlaceCandidate], mapping: [String: String]) {
        var kept: [PlaceCandidate] = []
        var mapping: [String: String] = [:]
        for place in list.sorted(by: { $0.id < $1.id }) {
            if let keeper = kept.first(where: { isSame($0, place) }) {
                mapping[place.id] = keeper.id
            } else {
                kept.append(place)
            }
        }
        return (kept, mapping)
    }
}

// MARK: - 事件命中規則（不確定度處理）

/// 事件定位只到行政區時（precisionMeters 3 公里以上，座標是行政區中心），誤差可達數公里。
/// 若直接把誤差整個加進命中距離，半徑 1 公里的守護地點會被 5 公里外的火災觸發。規則：
/// - 誤差加成上限 min(誤差, 圈半徑, 1000 公尺)；
/// - 行政區級事件對「守護地點」改用「同一行政區」判斷，不用（不可靠的）距離。
enum AlertMatchRule {
    /// 事件定位精度達此值以上＝只定位到行政區（或更大範圍）
    static let districtLevelPrecision = 3_000
    static let maxPrecisionBuffer: Double = 1_000

    static func precisionBuffer(precisionMeters: Int, radiusMeters: Int) -> Double {
        Double(max(0, min(precisionMeters, radiusMeters, Int(maxPrecisionBuffer))))
    }

    static func isDistrictLevel(precisionMeters: Int) -> Bool {
        precisionMeters >= districtLevelPrecision
    }

    /// 圈的行政區與事件行政區相同（任一邊未指定／未知都不算）
    static func isSameDistrict(circleDistrict: String, eventDistrict: String?, unspecified: String) -> Bool {
        guard let eventDistrict, !eventDistrict.isEmpty, eventDistrict != unspecified,
              !circleDistrict.isEmpty, circleDistrict != unspecified else { return false }
        return circleDistrict == eventDistrict
    }
}

// MARK: - 到達／離開事件

/// CLVisit 轉成的事件（系統判斷「在某處停留一段時間」）
struct VisitTransition: Equatable {
    let kind: ArrivalEvent.Kind
    let date: Date
    let latitude: Double
    let longitude: Double
}

/// 進出守護地點（CLCircularRegion）
struct RegionTransition: Equatable {
    let kind: ArrivalEvent.Kind
    let placeID: String
    let placeName: String
    let date: Date
}

/// 目前人在哪個守護地點內（持久化在 UserDefaults，App 被系統終止後重啟仍知道）
struct CurrentPlace: Codable, Equatable {
    let id: String
    let name: String
    let since: Date
}

enum VisitMapper {
    /// CLVisit 的 arrivalDate 可能是 .distantPast（系統不知道何時到）、departureDate 為 .distantFuture 表示還沒離開
    static func transition(
        arrival: Date, departure: Date, latitude: Double, longitude: Double, now: Date = .now
    ) -> VisitTransition {
        if departure == .distantFuture {
            return VisitTransition(
                kind: .arrive, date: arrival == .distantPast ? now : arrival,
                latitude: latitude, longitude: longitude
            )
        }
        return VisitTransition(kind: .depart, date: departure, latitude: latitude, longitude: longitude)
    }
}

struct ArrivalEvent: Identifiable, Equatable {
    enum Kind: String { case arrive, depart }
    enum Source: String { case region, visit }

    let id: String
    let uid: String
    let name: String
    let kind: Kind
    let source: Source
    let placeName: String
    let createdAt: Date

    func withName(_ newName: String) -> ArrivalEvent {
        ArrivalEvent(id: id, uid: uid, name: newName, kind: kind, source: source,
                     placeName: placeName, createdAt: createdAt)
    }

    /// 「小明到達家」「小明離開公司」；visit 沒有守護地點名時用「某處」
    var message: String {
        let place = placeName.isEmpty ? "某處" : placeName
        return kind == .arrive ? "\(name)到達\(place)" : "\(name)離開\(place)"
    }

    var timeText: String { LiveLocationPresence.clockText(createdAt) }
}

enum ArrivalPolicy {
    /// 家人 App 讀到比這更舊的事件時不再跳橫幅（避免久未開 App 一次噴出一堆過時通知）
    static let bannerMaxAge: TimeInterval = 30 * 60

    /// 篩出要跳橫幅的事件：別人的、守護地點進出（不含 visit）、夠新、還沒看過
    static func bannerCandidates(
        _ events: [ArrivalEvent],
        selfUID: String?,
        lastSeen: Date,
        now: Date = .now
    ) -> [ArrivalEvent] {
        events
            .filter {
                $0.uid != selfUID
                    && $0.source == .region
                    && $0.createdAt > lastSeen
                    && now.timeIntervalSince($0.createdAt) <= bannerMaxAge
            }
            .sorted { $0.createdAt < $1.createdAt }
    }
}

// MARK: - 家人主動「更新位置」

enum LocationRequestPolicy {
    /// 請求超過這麼久就當作過期、不再回應（對方手機早該回了，過期請求通常是舊的）
    static let maxAge: TimeInterval = 10 * 60
    /// 同一個人連續請求的冷卻時間（避免洗版與耗電）
    static let cooldown: TimeInterval = 60

    static func shouldAnswer(requestedAt: Date, lastHandledAt: Date?, now: Date = .now) -> Bool {
        guard now.timeIntervalSince(requestedAt) <= maxAge else { return false }
        if let lastHandledAt, requestedAt <= lastHandledAt { return false }
        return true
    }

    /// 回傳還要等幾秒才能再請求；0 代表可以
    static func cooldownRemaining(lastRequestAt: Date?, now: Date = .now) -> TimeInterval {
        guard let lastRequestAt else { return 0 }
        return max(0, cooldown - now.timeIntervalSince(lastRequestAt))
    }
}
