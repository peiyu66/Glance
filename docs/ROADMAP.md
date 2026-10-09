# Roadmap and acceptance gates

## Gate 0 — official authentication feasibility (not passed)

Before a complete app is built, verify an official Sign in with ChatGPT route on a physical iPhone. The current official flow specifies the system browser, PKCE, and an HTTP loopback callback on 127.0.0.1. Native iPhone callback handling and app lifecycle compatibility are not demonstrated by this repository. Do not assume custom URL scheme support.

References reviewed 2026-10-09:
- [Sign-in flow](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
- [Models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
- [Preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
- [Cookbook introduction](https://developers.openai.com/cookbook/articles/sign-in-with-chatgpt)

Real authorization must be initiated explicitly by the user. Any future implementation needs verified state and ID tokens, scoped account records, secure local credential storage, official refresh behavior, and revocation handling. Never reuse another app's credentials. List models for the authenticated account before choosing one; gpt-6-luna with reasoning.effort=none is only a candidate, not a verified account capability.

Acceptance requires a real-device callback, validated permissions and identity, account-specific model availability, one still-image request, and session renewal. No paid API fallback or remote relay is planned.

## Gate 1 — local mock (implemented)

SwiftUI iPhone shell and a pure Swift state machine. Target IDs are supplied by the mock, not inferred from images. Six core tests pass. Stable duration defaults to one second. Completed results are bounded in memory; old request IDs cannot overwrite a fresh request after reset or eviction. Empty/error completions are silent and not retried until eviction or foreground reset.

## Gate 2 — simulator (partially verified)

Simulator build, installation, launch, and initial screen inspection succeeded. Button interaction UI automation is not implemented. Host tests verify state behavior, not camera behavior or end-to-end UI interaction.

## Gate 3 — physical camera (not implemented)

Only after Gate 0 passes: local camera preview, central region stability, still capture, and on-device target matching. Turning a product over is a new target. Recognition returns all readable object names, text, and barcode values together; no mode selection or online product information lookup. The lower result area stays hidden while waiting or if nothing is recognized.

Test target changes and late responses, low light, front/back distinction, background return, recognition thresholds, latency, energy, and plan usage. Keep images in memory for the shortest practical time. Actual image lifecycle and matching thresholds remain implementation decisions to validate.

See the [next-stage task proposal](NEXT_STEPS.md) for the completed baseline, ordered tasks, acceptance criteria, and user approval gates. New stages require a separate decision.
