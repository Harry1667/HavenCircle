import SwiftUI
import SwiftData

/// App 根畫面：一律直接渲染主分頁（零導覽）。
/// 為什麼不再有著陸頁／新手精靈：冷啟動 0 點擊直接看到真實資料；
/// QR／深連結邀請碼在第一次啟動就能用（AppTabs 一出現就消耗 DeepLinkStore.pending）。
struct ContentView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        AppTabs()
            .task {
                // 只建「我」；跟隨圈要等使用者授權定位後才建（見 AppTabs）
                FirstRunSetup.ensureCurrentUser(context: modelContext)
            }
        #if DEBUG
            // 驗證用：--demo-firstrun 清掉三張引導卡的旗標並載入示範種子，供展覽彩排與截圖。
            .task {
                guard ProcessInfo.processInfo.arguments.contains("--demo-firstrun") else { return }
                FeedOnboardingFlags.reset()
                DemoSeed.loadHistoricalEvents(context: modelContext)
            }
        #endif
    }
}

#if DEBUG
#Preview {
    ContentView()
        .modelContainer(PreviewSupport.container())
}
#endif
