# Roadmap and acceptance gates

## Gate 0 — official authentication feasibility (not passed)

Before a complete app is built, verify an official Sign in with ChatGPT route on a physical iPhone. The current official flow specifies the system browser, PKCE, and an HTTP loopback callback on 127.0.0.1. The system authentication window and loopback callback worked on the tested physical iPhone; official sign-in and the authenticated model catalog have now passed. Image inference and session lifecycle acceptance remain pending. Do not assume custom URL scheme support.

References reviewed 2026-10-09:
- [Sign-in flow](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [Preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [Cookbook introduction](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt)

Real authorization must be initiated explicitly by the user. Any future implementation needs verified state and ID tokens, scoped account records, secure local credential storage, official refresh behavior, and revocation handling. Never reuse another app's credentials. List models for the authenticated account before choosing one; The tested catalog includes gpt-6-luna; reasoning.effort=none with image input still requires a successful request.

Acceptance requires a real-device callback, validated permissions and identity, account-specific model availability, one still-image request, and session renewal. No paid API fallback or remote relay is planned.

## Gate 1 — local mock (implemented)

SwiftUI iPhone shell and a pure Swift state machine. Target IDs are supplied by the mock, not inferred from images. Six core tests pass. Stable duration defaults to one second. Completed results are bounded in memory; old request IDs cannot overwrite a fresh request after reset or eviction. Empty/error completions are silent and not retried until eviction or foreground reset.

## Gate 2 — simulator (partially verified)

Simulator build, installation, launch, and initial screen inspection succeeded. Button interaction UI automation is not implemented. Host tests verify state behavior, not camera behavior or end-to-end UI interaction.

## Gate 3 — physical camera (not implemented)

Only after Gate 0 passes: local camera preview, central region stability, still capture, and on-device target matching. Turning a product over is a new target. Recognition returns all readable object names, text, and barcode values together; no mode selection or online product information lookup. The lower result area stays hidden while waiting or if nothing is recognized.

Test target changes and late responses, low light, front/back distinction, background return, recognition thresholds, latency, energy, and plan usage. Keep images in memory for the shortest practical time. Actual image lifecycle and matching thresholds remain implementation decisions to validate.

See the [next-stage task proposal](NEXT_STEPS.md) for the completed baseline, ordered tasks, acceptance criteria, and user approval gates. New stages require a separate decision.

Phase A is now authorized: an account-free loopback probe and two callback tests have been added. A signed iPhone build and installation passed after unlocking. Both 2-second and 45-second external-browser probes processed the callback only when Glance returned to the foreground; the automatic callback route failed the gate. At that historical stage official OAuth was untested. See [Phase A evidence](PHASE_A.md).

Update: Apple system authentication-window probes passed physical-device callbacks at 3.1s (2s delay) and 45.3s (45s delay), plus programmatic cancel and short-deadline timeout paths. Account-free feasibility is established for this device/OS; official authorization was still untested at the end of A2. See [Phase B](PHASE_B.md) for subsequent real sign-in and catalog evidence.
