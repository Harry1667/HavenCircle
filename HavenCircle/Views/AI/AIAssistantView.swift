import SwiftUI

/// 防災問答助理。
///
/// 成本/延遲設計（回應「AI 代理實測約 9 秒/則」的現實）：
/// 1. 常見問題（FAQ）的答案「內建為靜態內容」——點了瞬顯、零延遲、零 AI 費用；
/// 2. 只有使用者「自由發問」時才真的打 AI 代理（effort=low 壓延遲），並在行程內快取，
///    同一問題重問不重複計費；
/// 3. 伺服器端已有每 IP 每分鐘 20 次限流，避免濫用把 AI 帳單打爆。
///
/// 這頁由設定頁的 NavigationLink 推入，故本身不包 NavigationStack。
struct AIAssistantView: View {
    @State private var question = ""
    @State private var answer: String?
    @State private var isAsking = false
    @State private var askError: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        List {
            Section {
                Text("常見狀況可直接點下方問題（即時、免費）。也可以自己輸入問題，AI 會依台灣情境回答，思考約需數秒。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("常見問題") {
                ForEach(DisasterFAQ.items) { item in
                    DisclosureGroup {
                        Text(item.answer)
                            .font(.subheadline)
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                    } label: {
                        Label(item.question, systemImage: item.icon)
                            .font(.subheadline)
                    }
                }
            }

            Section("自己問一題") {
                TextField("例如：土石流警戒時該怎麼辦？", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                Button {
                    inputFocused = false
                    Task { await ask() }
                } label: {
                    HStack {
                        Label("詢問 AI", systemImage: "sparkles")
                            .foregroundStyle(HCColor.brandText)
                        if isAsking {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isAsking || question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if let askError {
                    Text(askError)
                        .font(.caption)
                        .foregroundStyle(HCColor.danger)
                }
                if let answer {
                    Text(answer)
                        .font(.subheadline)
                        .textSelection(.enabled)
                        .padding(.top, 2)
                    Text("AI 生成，僅供參考，不取代官方指示；有立即危險請直接撥 119 或 110。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("防災問答")
        .navigationBarTitleDisplayMode(.inline)
        .analyticsScreen("ai_assistant")
    }

    private func ask() async {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // 行程內快取：同一問題重問不重複計費
        if let cached = AIAssistantCache.store[trimmed] {
            answer = cached
            return
        }
        isAsking = true
        askError = nil
        defer { isAsking = false }
        do {
            let result = try await AIService.complete(prompt: DisasterFAQ.prompt(for: trimmed), effort: "low")
            let clean = result.trimmingCharacters(in: .whitespacesAndNewlines)
            answer = clean
            AIAssistantCache.store[trimmed] = clean
        } catch {
            askError = "詢問失敗：\(error.localizedDescription)"
            AppLog.cloudError("AI 防災問答失敗：\(error.localizedDescription)")
        }
    }
}

/// 內建的常見防災問答：答案為固定內容，點選即時顯示、不呼叫 AI（零延遲、零費用）。
/// 內容以台灣情境撰寫（119 火災救護、110 治安、1991 報平安專線、政府災防告警）。
enum DisasterFAQ {
    struct Item: Identifiable {
        let id = UUID()
        let icon: String
        let question: String
        let answer: String
    }

    static let items: [Item] = [
        Item(
            icon: "waveform.path.ecg",
            question: "地震發生時該怎麼辦？",
            answer: """
            記住「趴下、掩護、穩住（趴下、掩護、握緊）」：
            1. 立刻蹲低，躲到堅固桌子下，護住頭頸，抓住桌腳。
            2. 遠離窗戶、書櫃、吊燈等會倒塌掉落的物品。
            3. 搖晃停止前不要往外衝，多數傷害發生在慌亂移動時。
            4. 搖完後再開門、關瓦斯電源，循樓梯離開，勿搭電梯。
            5. 若受困，敲擊管線發出聲響求救，避免大量喊叫耗氧。
            """
        ),
        Item(
            icon: "hurricane",
            question: "颱風來之前要準備什麼？",
            answer: """
            颱風生成到登陸通常有數天，提早準備：
            1. 存三天份飲水、乾糧、常備藥、手電筒與行動電源。
            2. 清理陽台雜物、固定招牌與盆栽，膠帶貼窗防碎裂。
            3. 低窪或土石流潛勢區注意撤離通知，配合村里長疏散。
            4. 手機開啟「災防告警」，留意停班停課與河川水位。
            5. 淹水前把貴重物與電器移到高處，拔插頭避免漏電。
            """
        ),
        Item(
            icon: "flame.fill",
            question: "住家或大樓火災怎麼逃生？",
            answer: """
            「小火快逃、濃煙關門」：
            1. 發現火勢無法立即撲滅就逃，別戀財物，邊逃邊喊叫示警。
            2. 濃煙中壓低姿勢、沿牆前進，用濕毛巾摀口鼻。
            3. 逃生時關上背後的門，延緩火煙蔓延。
            4. 若門把發燙、外面全是濃煙，退回房內、塞住門縫、到窗邊求救，別貿然衝出。
            5. 逃出後不要再進入，到安全處撥打 119 說明地址與受困人數。
            """
        ),
        Item(
            icon: "water.waves",
            question: "淹水或積水時要注意什麼？",
            answer: """
            水的威脅常被低估：
            1. 及膝的流水就可能沖倒成人，不要涉水或開車強行通過。
            2. 遠離地下室、地下停車場，積水會迅速灌入。
            3. 先關閉淹水區域的電源總開關，避免感電。
            4. 往高樓層或高地避難，不要待在一樓等水退。
            5. 積水中可能有掀開的人孔蓋，避免行走危險路段。
            """
        ),
        Item(
            icon: "mountain.2.fill",
            question: "土石流警戒時該撤離嗎？",
            answer: """
            土石流潛勢區在颱風豪雨時風險最高：
            1. 收到紅色警戒或撤離通知，務必配合疏散，別心存僥倖。
            2. 聽到山區傳來悶雷般聲響、溪水變濁夾帶泥沙，是危險前兆，立即往高處遠離溪谷。
            3. 撤離時走預定的避難路線到避難收容所。
            4. 撤離前關閉水電瓦斯，攜帶證件與緊急包。
            5. 警報解除、政府確認安全前不要返家。
            """
        ),
        Item(
            icon: "bolt.slash.fill",
            question: "大範圍停電怎麼辦？",
            answer: """
            1. 先確認是自家跳電還是區域停電：檢查總開關，或看鄰居是否也停電。
            2. 減少開冰箱門，食物可保冷數小時。
            3. 使用手電筒照明，避免蠟燭引發火災。
            4. 拔掉電器插頭，防止復電瞬間電湧損壞。
            5. 停電查詢與通報可用台電 App 或客服專線 1911。
            """
        ),
        Item(
            icon: "backpack.fill",
            question: "緊急避難包要放什麼？",
            answer: """
            以「撐過 72 小時」為原則，放在隨手可取處：
            1. 飲水與即食乾糧、常備與慢性病藥物。
            2. 手電筒、行動電源、備用電池、哨子。
            3. 證件影本、少量現金、保暖衣物與輕便雨衣。
            4. 個人衛生用品、簡易急救包。
            5. 家人聯絡清單與集合地點（手機沒電也看得到的紙本）。
            """
        ),
        Item(
            icon: "bell.badge.fill",
            question: "收到災防告警通知該做什麼？",
            answer: """
            1. 先看清楚警報類型與影響區域，別急著關掉。
            2. 地震速報：立即就地掩護；其他警報依內容採取行動。
            3. 確認自己與家人是否在影響範圍，必要時互相聯繫。
            4. 依政府指示撤離或就地避難，不要靠謠言判斷。
            5. 安心圈只是輔助提醒，有立即危險請直接撥 119 或 110。
            """
        ),
        Item(
            icon: "person.2.wave.2.fill",
            question: "災後和家人失聯怎麼辦？",
            answer: """
            1. 災害時電話常打不通，改用簡訊、通訊軟體留言更容易送達。
            2. 撥打「1991 報平安留言專線」錄下你的狀況，家人可查詢。
            3. 事先和家人約定「集合地點」與「聯絡人」，分頭時照約定會合。
            4. 保持手機省電，只在必要時通話，把頻寬留給緊急通訊。
            5. 傷亡查詢可聯繫當地災害應變中心或警消單位。
            """
        ),
    ]

    /// 自由發問的提示詞：限定防災範圍、台灣情境、條列簡短，並保留 119/110 的安全提醒。
    static func prompt(for question: String) -> String {
        """
        你是台灣的防災助理。使用者問了一個問題，請用繁體中文、條列、200 字內回答，內容要符合台灣情境（火災救護撥 119、治安撥 110、報平安打 1991、留意政府災防告警）。
        若問題與防災、災害應變無關，請禮貌說明你只能回答防災相關問題。若涉及立即危險，提醒直接撥 119 或 110。直接回答，不要開場白。

        問題：\(question)
        """
    }
}

/// 防災問答自由發問的行程內快取：同一問題重問不重複計費（重啟 App 即清空）。
@MainActor
enum AIAssistantCache {
    static var store: [String: String] = [:]
}
