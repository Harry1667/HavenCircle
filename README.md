English | [繁體中文](README.zh-TW.md) | [日本語](README.ja.md)

# HavenCircle

Personalized disaster and safety alerts for Taiwan.

HavenCircle pulls incident data from around ten government and news sources, removes
duplicates, scores each event for reliability, and notifies you **only when something
happens inside a place you actually care about** — your home, your parents' house, your
child's school — during hours you chose.

Taiwan's disaster data is already public, but it is scattered across NCDR, the Central
Weather Administration, the National Fire Agency, sixteen city fire departments, the
Freeway Bureau, the Ministry of Environment, and the news. Nobody checks all of that
daily. Pushing every event is the same as pushing nothing: the noise makes people turn
notifications off. HavenCircle's product decision is subtraction.

**Status:** shipped on the App Store. iOS 17.0+, SwiftUI + SwiftData, with a widget
extension. Current version 1.2. Built solo.

## Availability

HavenCircle is **only available on the Taiwan App Store**:
<https://apps.apple.com/tw/app/id6791872200>

Every data source is a Taiwanese government agency or Taiwanese news outlet, and the
interface is in Traditional Chinese, so the app is not published elsewhere. If you search
for it in another country's App Store and find nothing, that is expected. The screenshots
and English descriptions below show what the app looks like.

## Screenshots

<table>
<tr>
<td align="center" valign="top" width="200"><img src="docs/appstore/marketing/final_01_map.png" width="170" alt="Safety map"></td>
<td align="center" valign="top" width="200"><img src="docs/appstore/marketing/final_02_home.png" width="170" alt="Home"></td>
<td align="center" valign="top" width="200"><img src="docs/appstore/marketing/final_03_eventlist.png" width="170" alt="Alert center"></td>
<td align="center" valign="top" width="200"><img src="docs/appstore/marketing/final_04_eventdetail.png" width="170" alt="Event detail"></td>
<td align="center" valign="top" width="200"><img src="docs/appstore/marketing/final_05_family.png" width="170" alt="Family"></td>
</tr>
<tr>
<td valign="top"><sub><b>Safety map.</b> Headline: "Know Taiwan's safety status at a glance." A map of the Taipei area with shaded alert zones, pins for named places ("Grandma's home", "Warehouse", "Mom's office"), a red "2 items need attention" banner, and a bottom card for a nearby event ("being confirmed, 11 hours ago, 500 m from Mom's office").</sub></td>
<td valign="top"><sub><b>Home.</b> Headline: "Report you're safe in one tap." A red shield reads "2 events near your alert zones" with a "View map" button. Below, each person or place in the circle is listed (Warehouse: factory fire, heavy smoke, about 1.4 km; Grandma: multi-vehicle collision, about 1.1 km). A blue "I'm safe" button sits at the bottom.</sub></td>
<td valign="top"><sub><b>Alert center.</b> Headline: "Spot nearby dangers anytime." Two tabs, "Relevant to me" and "Nationwide", with the note that notifications follow your own circles and settings. A small map shows an alert circle, followed by a list of regional natural-disaster alerts (here flood warnings from rain gauge stations being lifted), 14 in total.</sub></td>
<td valign="top"><sub><b>Event detail.</b> Headline: "Read detailed incident reports." An incident report marked "Ongoing, officially confirmed", with a suggested action (move away, find cover, call 110), an official description, an "Alert judgment" line saying the event is outside every active alert zone, and an "AI analysis: how this affects me" button.</sub></td>
<td valign="top"><sub><b>Family.</b> Headline: "Invite family to protect together." An empty state ("When disaster strikes, one person knowing isn't enough") with "Sign in and invite family" (Apple account, about 10 seconds) and "Enter invite code to join". A note says location sharing is decided by each person and off by default.</sub></td>
</tr>
</table>

---

## How it works

Users first declare what they care about — family members, and guarded places with a
radius and a time window. Everything else follows from that.

```
parallel fetch from ~10 providers
  → grid-based deduplication (EventClustering)
  → three-tier trust scoring
  → AlertPolicy: does this intersect the user's life circle?
  → notify (local / APNs)
  → archive after 7 days
```

`Services/EventPipeline.swift` is the core of the app. Two rules are enforced in code
and documented in comments:

- **`SafetyOverview` and `AlertPolicy` are the only two decision entry points, and both
  are required to read the _unfiltered_ event set.** Computing a safety status from
  already-filtered data produces false reassurance — a green light while something is
  burning next door.
- **Life-safety alerts (fire, earthquake, typhoon) are never gated behind payment.**
  No paywall check runs on that path.

## Data sources

Every provider documents at the top of its file how it complements the others, so
coverage overlaps as little as possible.

| Provider | Source | Shape |
|---|---|---|
| `NCDRPointEventProvider` / `NCDRRegionAlertProvider` | National Science and Technology Center for Disaster Reduction | point events + regional alerts |
| `CWARegionAlertProvider` | Central Weather Administration | earthquake reports, weather warnings |
| `NFAIncidentProvider` | National Fire Agency | nationwide incidents |
| `CityFireIncidentProvider` | 16 municipal fire departments | finest granularity (down to ~300 m) |
| `TaichungFireEventProvider` | Taichung City Fire Bureau | separate implementation |
| `FreewayIncidentProvider` | Freeway Bureau | highway incidents |
| `AirQualityEventProvider` | Ministry of Environment | air quality |
| `NewsEventProvider` | major news outlets | rules first, LLM only fills gaps |

The app never talks to these sites directly. A self-hosted relay crawler normalizes
every feed, so a single broken municipal website cannot stall the app.
`AlertSourceHealthService` keeps a health snapshot per source.

`CrimeReferenceService` reads crime statistics but deliberately **never** raises alerts
from them — retrospective statistics pushed as notifications only manufacture anxiety.

## Main screens

| Tab | File | Purpose |
|---|---|---|
| Home | `Views/Home/HomeStatusView.swift` | safety status overview and the alert center |
| Safety Map | `Views/Map/SafetyMapView.swift` | alert radii, event pins, environmental layers |
| Family | `Views/Family/FamilyHubView.swift` | members, life circles, live location, "I'm safe" check-ins |

## Privacy and security

- **Home addresses are encrypted with AES-GCM** before storage (`AddressCrypto`).
- **The widget extension never reads location or address data directly.** It renders
  from App Group snapshots only, so widget code has no access to the sensitive set.
- **Firestore rules scope all family data to circle members.** Reads require
  membership; each member may write only their own location and status documents.
  See `firestore.rules`.
- **No LLM credentials ship in the client.** The AI assistant calls a server-side
  proxy; the app holds no upstream keys.
- Remote configuration can change data and settings only — never executable code —
  to stay inside App Store Guideline 2.5.2.

## Tech

Swift · SwiftUI · SwiftData · MapKit · WidgetKit · StoreKit 2 · BGTaskScheduler ·
Firebase (Auth with Sign in with Apple, Firestore, FCM) · fastlane and the App Store
Connect API for submission.

Roughly 20,800 lines of Swift across 105 files.

## How it was built

Apart from the first point, everything below can be checked in this repository.

- **Built with Claude Code, skeleton first.** The author decided the requirements, user
  flows and tech stack, working them through with Claude, and fixed them as the project's
  rules and spec. Only then did Claude Code implement, task by task, inside that skeleton.
- **`AGENTS.md`** is the working agreement for AI contributors: product guardrails
  (non-emergency disclaimer, opt-in location sharing, no color-only status) and
  engineering conventions.
- **Builds are verified with `xcodebuild`** after Swift changes, as `AGENTS.md` requires.
- **22 UI tests** (`func test…` in `HavenCircleUITests/HavenCircleUITests.swift`).
- **About 200 commits**, with the day-by-day development log in `SESSION_NOTES.md`.

## Repository layout

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

## Build

Requires Xcode with an iOS 17.0+ SDK and a Firebase project.

```bash
open HavenCircle.xcodeproj
```

`GoogleService-Info.plist` is committed on purpose. It contains no secrets: Firebase
iOS configuration is a public client identifier that ships inside every distributed
`.ipa` anyway, and access control is enforced by the Firestore security rules in this
repository rather than by hiding this file. Actual secrets — APNs `.p8` keys, service
account JSON, signing certificates — are gitignored and never enter the repository.

## Note on language

The app's interface and most documents under `docs/` are written in Traditional Chinese,
because the product serves Taiwan and its data sources publish in Chinese. Code, comments
in shared modules, and this README are in English.
