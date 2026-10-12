[English](README.md) | [繁體中文](README.zh-TW.md) | 日本語

# HavenCircle

台湾向けの、パーソナライズされた災害・安全アラート。

HavenCircle は、政府機関とニュースの約 10 か所のソースから事件データを取得し、重複を除き、
各イベントの信頼度を採点します。そして、**あなたが本当に気にかけている場所**（自宅、両親の家、
子どもの学校）で何かが起きたときに、あなたが指定した時間帯にだけ通知します。

台湾の災害データはすでに公開されていますが、NCDR、中央気象署、消防署、16 の市の消防局、
高速道路局、環境部、そしてニュースに散らばっています。それらを毎日すべて確認する人はいません。
すべてのイベントを通知することは、何も通知しないのと同じです。ノイズが多いと、人は通知を
オフにします。HavenCircle の製品方針は「引き算」です。

**ステータス:** App Store で公開済み。iOS 17.0+、SwiftUI + SwiftData、ウィジェット拡張つき。
現在のバージョンは 1.2。個人で開発しています。

## 提供地域

HavenCircle は**台湾の App Store でのみ提供**されています:
<https://apps.apple.com/tw/app/id6791872200>

すべてのデータソースが台湾の政府機関または台湾のニュースメディアであり、画面も繁体字中国語の
ため、他の地域では公開していません。他の国の App Store で検索しても見つからないのは想定どおり
です。アプリの見た目は、以下のスクリーンショットと説明でご確認ください。

## スクリーンショット

<table>
<tr>
<td align="center" valign="top" width="200"><img src="docs/appstore/marketing/final_01_map.png" width="170" alt="安全マップ"></td>
<td align="center" valign="top" width="200"><img src="docs/appstore/marketing/final_02_home.png" width="170" alt="ホーム"></td>
<td align="center" valign="top" width="200"><img src="docs/appstore/marketing/final_03_eventlist.png" width="170" alt="アラートセンター"></td>
<td align="center" valign="top" width="200"><img src="docs/appstore/marketing/final_04_eventdetail.png" width="170" alt="イベント詳細"></td>
<td align="center" valign="top" width="200"><img src="docs/appstore/marketing/final_05_family.png" width="170" alt="家族"></td>
</tr>
<tr>
<td valign="top"><sub><b>安全マップ。</b>見出し: 「台湾全土の安全状況を把握」。台北周辺の地図に、警戒範囲の色付きエリア、名前を付けた場所のピン（「おばあちゃんの家」「倉庫」「お母さんの会社」）、赤い「2 件要注意」バナー、下部に近くのイベントのカード（「確認中、11 時間前、お母さんの会社から 500 m」）が表示されています。</sub></td>
<td valign="top"><sub><b>ホーム。</b>見出し: 「ワンタップで無事を報告」。赤い盾に「2 件のイベントが警戒圏に接近」と表示され、「地図を見る」ボタンがあります。その下に、サークル内の人や場所が並びます（倉庫: 工場火災・濃煙、約 1.4 km。おばあちゃん: トレーラーとバイクの衝突、約 1.1 km）。下部に青い「無事を報告」ボタンがあります。</sub></td>
<td valign="top"><sub><b>アラートセンター。</b>見出し: 「身の回りの危険をいつでも発見」。「自分に関係あり」と「全台湾の動き」の 2 つのタブがあり、通知は自分のサークルと設定に基づいてのみ送られるという説明が付いています。小さな地図に警戒円が表示され、その下に地域の自然災害アラート一覧（ここでは雨量観測所の浸水警報の解除）が全 14 件並びます。</sub></td>
<td valign="top"><sub><b>イベント詳細。</b>見出し: 「詳細な事件レポートを読む」。「進行中・公的に確認済み」と表示された事件レポートで、推奨行動（現場から離れる、身を隠す、110 に通報）、公式の説明、「警戒判定」の行（イベントは有効な警戒圏の範囲外）、「AI 分析: この事件が自分に与える影響」ボタンがあります。</sub></td>
<td valign="top"><sub><b>家族。</b>見出し: 「家族を招待して一緒に守る」。空の状態の画面（「災害のとき、1 人が知っているだけでは足りない」）に、「ログインして家族を招待」（Apple アカウント、約 10 秒）と「招待コードを入力して参加」があります。位置共有は各自が決め、初期設定はオフという説明が付いています。</sub></td>
</tr>
</table>

---

## 仕組み

ユーザーはまず、自分が気にかけるもの（家族、そして半径と時間帯を持つ見守り場所）を宣言します。
それ以外はすべてそこから決まります。

```
parallel fetch from ~10 providers
  → grid-based deduplication (EventClustering)
  → three-tier trust scoring
  → AlertPolicy: does this intersect the user's life circle?
  → notify (local / APNs)
  → archive after 7 days
```

`Services/EventPipeline.swift` がアプリの中核です。次の 2 つのルールがコードで強制され、
コメントにも記載されています。

- **`SafetyOverview` と `AlertPolicy` が唯一の 2 つの判定入口であり、どちらも「フィルタ前」の
  イベント集合を読むことが必須です。** すでにフィルタされたデータから安全状態を計算すると、
  誤った安心感を生みます。隣で火事が起きているのに、緑のランプが点くのです。
- **人命に関わるアラート（火災、地震、台風）は決して課金の後ろに置きません。** その経路では
  課金チェックは一切実行されません。

## データソース

各 provider は、他のソースとどう補完し合うかをファイルの冒頭に記載しており、カバー範囲の
重複を最小限にしています。

| Provider | ソース | 形式 |
|---|---|---|
| `NCDRPointEventProvider` / `NCDRRegionAlertProvider` | 国家災害防救科技中心 | ポイントイベント＋地域アラート |
| `CWARegionAlertProvider` | 中央気象署 | 地震報告、気象警報 |
| `NFAIncidentProvider` | 内政部消防署 | 全国の事件 |
| `CityFireIncidentProvider` | 16 の市の消防局 | 最も細かい粒度（約 300 m） |
| `TaichungFireEventProvider` | 台中市消防局 | 独立した実装 |
| `FreewayIncidentProvider` | 高速公路局 | 高速道路の事件 |
| `AirQualityEventProvider` | 環境部 | 大気質 |
| `NewsEventProvider` | 主要ニュースメディア | ルール優先、LLM は欠けた部分のみ補完 |

アプリがこれらのサイトに直接アクセスすることはありません。自前のリレー用クローラがすべての
フィードを正規化するため、ある市のサイトが 1 つ壊れてもアプリは止まりません。
`AlertSourceHealthService` は、ソースごとのヘルススナップショットを保持します。

`CrimeReferenceService` は犯罪統計を読み取りますが、そこからアラートを出すことは意図的に
**しません**。過去の統計を通知として送っても、不安を生むだけだからです。

## 主な画面

| タブ | ファイル | 役割 |
|---|---|---|
| ホーム | `Views/Home/HomeStatusView.swift` | 安全状態の概要とアラートセンター |
| 安全マップ | `Views/Map/SafetyMapView.swift` | 警戒半径、イベントピン、環境レイヤー |
| 家族 | `Views/Family/FamilyHubView.swift` | メンバー、ライフサークル、リアルタイム位置、「無事です」チェックイン |

## プライバシーとセキュリティ

- **自宅の住所は保存前に AES-GCM で暗号化されます**（`AddressCrypto`）。
- **ウィジェット拡張は位置情報や住所データを直接読みません。** App Group のスナップショット
  のみから描画するため、ウィジェットのコードは機微なデータに触れられません。
- **Firestore ルールにより、家族データはすべてサークルのメンバーに限定されます。** 読み取りには
  メンバーシップが必要で、各メンバーが書き込めるのは自分の位置とステータスのドキュメント
  だけです。`firestore.rules` を参照してください。
- **クライアントに LLM の認証情報は含まれません。** AI アシスタントはサーバー側のプロキシを
  呼び出し、アプリは上流のキーを一切持ちません。
- リモート設定で変更できるのはデータと設定のみで、実行可能コードは決して変更できません。
  App Store Guideline 2.5.2 に準拠するためです。

## 技術

Swift · SwiftUI · SwiftData · MapKit · WidgetKit · StoreKit 2 · BGTaskScheduler ·
Firebase (Auth with Sign in with Apple, Firestore, FCM) · fastlane and the App Store
Connect API for submission.

Roughly 20,800 lines of Swift across 105 files.

（Swift 約 20,800 行、105 ファイル。）

## 開発の進め方

最初の項目を除き、以下はすべてこのリポジトリ内で確認できます。

- **Claude Code で開発、まず骨組みから。** 作者が要件・ユーザーフロー・技術スタックを決め、Claude と議論しながらプロジェクトのルールと仕様として固めました。その上で初めて、Claude Code がその骨組みの中でタスクごとに実装しました。
- **`AGENTS.md`** は AI コントリビューター向けの作業ルールです。製品上のガードレール
  （非緊急サービスである旨の表示、位置共有は本人の同意によるオプトイン、状態表示を色だけに
  頼らない）とエンジニアリング規約が書かれています。
- **Swift のコードを変更したら `xcodebuild` でビルドを検証**します。`AGENTS.md` の要求です。
- **22 件の UI テスト**（`HavenCircleUITests/HavenCircleUITests.swift` の `func test…`）。
- **約 200 コミット**。日ごとの開発ログは `SESSION_NOTES.md` にあります。

## リポジトリ構成

```
HavenCircle/            main app target
HavenCircleWidget/      widget extension
docs/                   design, UX, data-source and App Store notes (Chinese)
  appstore/             submission material and review checklists
  ux/                   user-flow studies and walkthrough reports
  data-sources/         per-source research notes
  engineering/          push and CloudKit setup notes
  planning/             development and monetization plans
fastlane/               build and submission lanes
website/                marketing site and server-side endpoints
tools/                  crawler and maintenance scripts
test/                   test fixtures
AGENTS.md               working agreement for AI contributors
SESSION_NOTES.md        development log
```

## ビルド

iOS 17.0+ SDK を含む Xcode と、Firebase プロジェクトが必要です。

```bash
open HavenCircle.xcodeproj
```

`GoogleService-Info.plist` は意図的にコミットしています。機密は含まれません。Firebase の iOS
設定は公開のクライアント識別子で、配布されるすべての `.ipa` に同梱されるものです。アクセス制御は
このファイルを隠すことではなく、このリポジトリ内の Firestore セキュリティルールで行っています。
本当の機密（APNs の `.p8` キー、サービスアカウント JSON、署名証明書）は gitignore されており、
リポジトリには決して入りません。

## 言語について

アプリの画面と `docs/` 配下のほとんどのドキュメントは、製品が台湾向けで、データソースも中国語で
公開されているため、繁体字中国語で書かれています。コード、共有モジュール内のコメント、そして
この README は英語（および翻訳版）です。
