# Glance

An early, open-source iPhone experiment for recognizing objects, visible text, and barcode values from a single image after the center of the camera view is stable.

**Current state: local mock only.** The app does not connect to a camera, sign in, make network requests, or recognize real images. Native iPhone compatibility with official Sign in with ChatGPT remains an unpassed feasibility gate. A ChatGPT Pro subscription alone does not prove this integration works.

## Run the mock

Requires Xcode with an iOS Simulator runtime; deployment target iOS 17. Tested with Xcode 27.0 and an iPhone 17 simulator running iOS 27.0.

1. Open `Glance.xcodeproj` and select the Glance scheme and an iPhone simulator.
2. Run the app. The Chinese buttons 正面 (front), 背面 (back), and 移開 (away) simulate targets.
3. Keep a target selected for one second to show sample results at the bottom. Selecting away hides them immediately.

These controls are development fixtures, not recognition modes in the intended product.

```sh
swift test --scratch-path /tmp/Glance-build
xcodebuild -project Glance.xcodeproj -scheme Glance -sdk iphonesimulator \
  -configuration Debug -derivedDataPath /tmp/Glance-derived \
  CODE_SIGNING_ALLOWED=NO build
```

The six core tests cover stability, deduplication, stale responses, returning targets, target removal, independent reverse sides, silent empty results, cache eviction, and foreground reset. Core tests run on the host; simulator launch does not verify a real camera or authentication.

## Scope and privacy

- iPhone first; no product database lookup, sharing, or encyclopedic explanations.
- Intended behavior: one stable central target triggers one still-image request; readable names, text, and barcode values appear together.
- Pending, empty, or failed recognition stays silent. Results hide when the target leaves.
- No persistent photos or sensitive logs. The mock stores at most eight target entries in memory and clears them when leaving the foreground.
- No API-key billing fallback, borrowed app tokens, or remote authentication relay.

See [roadmap and acceptance gates](docs/ROADMAP.md) and the [next-stage task proposal](docs/NEXT_STEPS.md). This repository contains no credentials or live authentication implementation. MIT licensed; see [LICENSE](LICENSE).
