# Glance

An early, open-source iPhone experiment for recognizing objects, visible text, and barcode values from a single image after the center of the camera view is stable.

**Current state: mock camera UI plus a verified native ChatGPT sign-in and synthetic-image path.** On the tested physical iPhone, official sign-in, identity/permission checks, device-only Keychain storage, cold-start session restoration and the authenticated model catalog passed. `gpt-6-luna` with `reasoning.effort=none` returned `response.completed` in about 2.58 seconds and correctly read a generated red square and “GLANCE 123”. Natural token refresh and revocation remain untested, so the full lifecycle gate is still open. No real camera is implemented. See [Phase B evidence](docs/PHASE_B.md) and [account-free callback probes](docs/PHASE_A.md).

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

The six recognition-state tests cover stability, deduplication, stale responses, returning targets, target removal, independent reverse sides, silent empty results, cache eviction, and foreground reset. Two additional tests cover synthetic callback validation and replay rejection. Nine further SIWC protocol tests cover PKCE, callbacks, signed identity validation, request construction and stream completion (17 total tests). Core tests run on the host; simulator launch does not verify a real camera or authentication.

## Scope and privacy

- iPhone first; no product database lookup, sharing, or encyclopedic explanations.
- Intended behavior: one stable central target triggers one still-image request; readable names, text, and barcode values appear together.
- Pending, empty, or failed recognition stays silent. Results hide when the target leaves.
- No persistent photos or sensitive logs. The mock stores at most eight target entries in memory and clears them when leaving the foreground.
- No API-key billing fallback, borrowed app tokens, or remote authentication relay.

See [roadmap and acceptance gates](docs/ROADMAP.md) and the [next-stage task proposal](docs/NEXT_STEPS.md). The optional `--siwc-validation` launch argument opens the validation screen. Sign-in and inference require explicit user actions; no credentials are included in this repository. Do not use the test-only `--siwc-start` flag without explicit authorization for that sign-in attempt. MIT licensed; see [LICENSE](LICENSE).
