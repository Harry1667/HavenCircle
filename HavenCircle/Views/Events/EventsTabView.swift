import SwiftUI

/// 「動態」分頁（原提醒中心升格）：第二個一級分頁。
/// 導航堆疊綁在 router 上：deep link（widget／通知的 alerts）切到本分頁後可直接推入回顧。
/// 底部依序是「回顧過去 N 天」與「防災問答」——低頻功能收在動態的最下面，不佔首頁。
struct EventsTabView: View {
    @Environment(TabRouter.self) private var router

    var body: some View {
        NavigationStack(path: Bindable(router).eventsPath) {
            EventListView()
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        FeedSettingsButton { router.showSettings = true }
                    }
                }
                .navigationDestination(for: TabRouter.EventsDestination.self) { destination in
                    switch destination {
                    case .history: HistoryView()
                    }
                }
        }
    }
}
