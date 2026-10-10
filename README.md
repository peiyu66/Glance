# Glance

A personal iPhone prototype that sends one still image after the center of the camera view is stable, then shows readable object names, text and barcode values together.

**Current state: the native ChatGPT Pro path works; the camera prototype is implemented but real-camera display acceptance is still open.** Official sign-in, identity/scope checks, device-only Keychain storage, model discovery, cold-start restoration and one natural token refresh passed on the tested iPhone. The model is `gpt-6-luna`, with `reasoning.effort=none`; no API-key billing fallback exists. See [Phase B](docs/PHASE_B.md) and [Phase C](docs/PHASE_C.md).

The first real-camera trial returned a nonempty result, but target matching prevented display. A subsequent physical-device generated-card replay passed seven identity cases and all twelve controller checks, including shifted-card first-result visibility, distinct one-character labels, cached return and late-result isolation. It uses real Vision and the production text reader with an injected provider; live-camera display and actual recognition latency still need acceptance. See [Phase C](docs/PHASE_C.md) for failures, fixes and test rationale.

## Run

Open `Glance.xcodeproj`, choose the Glance scheme and an iPhone. Deployment target is iOS 17; the current build was tested with Xcode 27.0. Physical deployment requires your own signing configuration. No credentials are included.

The normal launch opens the camera page with capture paused. Configure the account through Settings, complete official authorization yourself, and verify plan/extra-credit settings at the official Usage page. Tap 開始取景 only after choosing an item you are comfortable sending. Hold the center target steady; one second is the trigger threshold, not a promise that the model finishes in one second. Results appear at the bottom when available. 暫停, opening settings, or leaving the foreground stops capture and clears temporary results. Returning to an active capture requires stability again.

Unfinished, empty and failed recognition stays silent on the camera page. Settings has status categories, request counts and timing; no ordinary recognized text or photos are logged.

## Verification

```sh
swift test --scratch-path /tmp/Glance-build
xcodebuild -project Glance.xcodeproj -scheme Glance -sdk iphonesimulator \
  -configuration Debug -derivedDataPath /tmp/Glance-derived \
  CODE_SIGNING_ALLOWED=NO build
```

34 host tests cover authentication and streaming, stable-target state, cancellation, late responses, bounded caches, image motion, quality checks, identity uncertainty and request admission. Test launch arguments are development tools:

- `--mock`: original button-driven state demonstration.
- `--camera-local-fixture`: generated-card matcher/controller replay; no live camera and no model requests.
- `--camera-trial-once`: normal camera UI with at most one image request for a bounded engineering trial; the user still starts capture.
- `--siwc-validation`: account validation page. Do not use automatic sign-in or network fixture flags without authorization.

Simulator launch and injected-provider timing do not prove real camera, Vision matching, network latency or battery performance.

## Scope and privacy

Central camera samples are processed locally at up to four per second. A stable, eligible target triggers one JPEG request; there is one request in flight and a minimum four-second gap. A short memory cache has at most eight targets and a 90-second lifetime. A product's back is a separate target; cross-face aggregation is not implemented.

A local text digest helps reject conflicting labels during target matching. That local text is not shown as a result, logged or persisted; displayed recognition still comes from the authorized Pro provider. Matching thresholds and OCR stability require further device validation. No matcher can currently claim that all similar packaging is distinguished.

No persistent photos, sensitive logs, borrowed app tokens, remote auth relay, product database lookup, sharing or commercial features. See the [plan and test rationale](docs/PHASE_C.md), [acceptance gates](docs/ROADMAP.md), [next work](docs/NEXT_STEPS.md), and [report](docs/Glance-專案與認證試驗報告.md). MIT licensed.
