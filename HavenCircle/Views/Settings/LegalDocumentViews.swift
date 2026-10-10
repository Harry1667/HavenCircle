import SwiftUI

struct LegalCenterView: View {
    var body: some View {
        List {
            Section {
                ForEach(LegalDocumentKind.allCases) { document in
                    NavigationLink {
                        LegalDocumentView(document: document)
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.title)
                                Text(document.subtitle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: document.symbol)
                                .foregroundStyle(HCColor.brandText)
                        }
                    }
                }
            } footer: {
                Text("修訂日期：\(LegalDocumentKind.revision)。App 內保留可離線閱讀的版本；網站提供同版公開連結。")
            }

            Section("重要提醒") {
                Label("安心圈不是緊急服務；遇立即危險請直接撥打 110 或 119。", systemImage: "phone.fill")
                    .foregroundStyle(HCColor.danger)
            }

            Section("法律文件狀態") {
                Text("本文件依目前原型的真實資料流撰寫，並非個別法律意見。正式公開營運前，仍應由具資格的法律專業人員審閱，並補齊法定營運者資料。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("法律與隱私")
        .navigationBarTitleDisplayMode(.inline)
        .analyticsScreen("legal")
    }
}

struct LegalDocumentView: View {
    let document: LegalDocumentKind

    var body: some View {
        List {
            Section {
                Text(document.introduction)
                    .font(.body)
                LabeledContent("修訂日期", value: LegalDocumentKind.revision)
                    .font(.footnote)
            }

            ForEach(document.sections) { section in
                Section(section.title) {
                    ForEach(Array(section.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.callout)
                            .textSelection(.enabled)
                    }
                }
            }

            Section {
                Link("在官方網站查看最新版", destination: document.webURL)
                Link("以 Email 聯絡安心圈", destination: URL(string: "mailto:hello@havencircle.app")!)
            }

            Section {
                Label("安心圈不是緊急服務；遇立即危險請直接撥打 110 或 119。", systemImage: "phone.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(HCColor.danger)
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        LegalCenterView()
    }
}
