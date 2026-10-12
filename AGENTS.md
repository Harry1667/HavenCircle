# HavenCircle contributor guide

## Product guardrails

- HavenCircle is a family safety-awareness product, not an emergency service. Keep the non-emergency disclaimer and clear 110 / 119 escalation path visible where relevant.
- Family live-location sharing must be opt-in on each person’s own device, visibly active, pausable at any time, and limited to members of the user’s family circle.
- Always show the last update time for live circles. Treat locations older than 15 minutes as stale and exclude them from alert decisions; never present stale data as live.
- Keep live circles and fixed circles distinct in both data and UI. Fixed circles represent user-named assets or places such as homes and warehouses.
- Never send family locations to the HavenCircle alert relay. Family locations live only in the family circle’s Firestore documents, readable by circle members only (see `firestore.rules`).
- Do not rely on color alone for risk or verification state; every status needs a plain-language label.
- Treat community information as unverified unless an official source or corroboration is explicitly represented.
- Prefer approximate event locations in UI and avoid collecting unnecessary personal data.

## Engineering conventions

- Keep views deterministic and usable in Xcode previews.
- Use SwiftUI and MapKit system APIs before adding third-party dependencies.
- Keep user-facing strings in Traditional Chinese.
- Verify builds with `xcodebuild` after changing Swift source when the local toolchain is available.
