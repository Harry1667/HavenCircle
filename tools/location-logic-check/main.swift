import Foundation
enum Districts { static let unspecified = "未指定" }
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
func S(_ m: Double, _ dLat: Double = 0) -> LocationSample { LocationSample(time: t0.addingTimeInterval(m*60), latitude: 25.0 + dLat, longitude: 121.5) }
var fails = 0
func check(_ c: Bool, _ m: String) { if !c { print("FAIL:", m); fails += 1 } else { print("ok:", m) } }
var d = MotionDetector()
d.ingest(S(0)); d.ingest(S(2, 0.0001)); check(d.state == .moving, "2 分鐘仍 moving")
d.ingest(S(4.5, 0.0001)); check(d.state == .stationary, "4.5 分鐘位移 ~11m → stationary")
d.ingest(S(10, 0.0005)); check(d.state == .stationary, "位移 ~55m 仍 stationary")
d.ingest(S(11, 0.002)); check(d.state == .moving, "位移 ~220m → moving")
var d2 = MotionDetector()
d2.ingest(S(0)); d2.ingest(S(3, 0.001)); d2.ingest(S(5, 0.002)); check(d2.state == .moving, "持續移動不判靜止")
check(UploadThrottle.shouldUpload(previous: S(0), current: S(0.2)) == false, "10 秒內不傳")
check(UploadThrottle.shouldUpload(previous: S(0), current: S(0.6)), "36 秒傳")
check(UploadThrottle.shouldUpload(previous: S(0), current: S(0.1, 0.003)), "10 秒但位移 >200m 傳")
check(TrailPolicy.cutoff(now: t0) == t0.addingTimeInterval(-86400), "cutoff 24h")
check(TrailPolicy.expireAt(for: t0) == t0.addingTimeInterval(86400), "expireAt +24h")
check(TrailPolicy.shouldAppendPoint(previous: S(0), current: S(3)) == false, "靜止 3 分鐘不加點")
check(TrailPolicy.shouldAppendPoint(previous: S(0), current: S(11)), "10 分鐘加點")
check(TrailPolicy.shouldCleanup(lastCleanupAt: t0, now: t0.addingTimeInterval(300)) == false, "清理節流")
let places = (0..<25).map { GeofencePlace(id: "\($0)", name: "p\($0)", latitude: 25 + Double($0)*0.01, longitude: 121.5) }
let sel = GeofencePlanner.select(places, near: (25.24, 121.5))
check(sel.count == 20 && sel.contains { $0.id == "24" } && !sel.contains { $0.id == "0" }, "取最近 20 個")
let tz = TimeZone(identifier: "Asia/Taipei")!
let now = t0.addingTimeInterval(120)
let since = t0 // 
print(LiveLocationPresence.statusText(lastReportedAt: t0, stationarySince: t0, placeName: "家", placeSince: t0, now: now, timeZone: tz))
print(LiveLocationPresence.statusText(lastReportedAt: t0, stationarySince: t0, now: now))
print(LiveLocationPresence.statusText(lastReportedAt: t0, stationarySince: t0.addingTimeInterval(-3000), district: "大安區", now: now))
print(LiveLocationPresence.statusText(lastReportedAt: t0.addingTimeInterval(-1200), stationarySince: nil, now: now))
check(LiveLocationPresence.statusText(lastReportedAt: t0, stationarySince: t0, placeName: "家", placeSince: t0, now: now, timeZone: tz).hasPrefix("在家・從 "), "在家文案")
let ev = ArrivalEvent(id: "1", uid: "a", name: "小明", kind: .arrive, source: .region, placeName: "家", createdAt: t0)
check(ev.message == "小明到達家", "到達文案")
check(ArrivalPolicy.bannerCandidates([ev], selfUID: "a", lastSeen: t0.addingTimeInterval(-10), now: t0).isEmpty, "自己的事件不跳橫幅")
check(ArrivalPolicy.bannerCandidates([ev], selfUID: "b", lastSeen: t0.addingTimeInterval(-10), now: t0.addingTimeInterval(60)).count == 1, "別人的事件跳橫幅")
check(ArrivalPolicy.bannerCandidates([ev], selfUID: "b", lastSeen: t0.addingTimeInterval(-10), now: t0.addingTimeInterval(3600)).isEmpty, "太舊不跳")
check(LocationRequestPolicy.shouldAnswer(requestedAt: t0, lastHandledAt: nil, now: t0.addingTimeInterval(30)), "請求有效")
check(!LocationRequestPolicy.shouldAnswer(requestedAt: t0, lastHandledAt: t0, now: t0.addingTimeInterval(30)), "已處理不重複")
check(!LocationRequestPolicy.shouldAnswer(requestedAt: t0, lastHandledAt: nil, now: t0.addingTimeInterval(700)), "過期不回")
print(fails == 0 ? "ALL PASS" : "FAILS \(fails)")
