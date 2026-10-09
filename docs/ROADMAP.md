# Acceptance gates

Updated 2026-10-09. This is an evidence summary; [Phase C](PHASE_C.md) owns the current hypotheses, test rationale and decisions.

| Gate | Evidence | Status |
| --- | --- | --- |
| Native Pro feasibility | Official OAuth, identity/scope validation, Keychain storage, authenticated model catalog, completed synthetic image | Passed for the tested account/device; not a universal support claim |
| Session lifecycle | Cold-start restoration and one natural refresh | Passed for those paths; revocation not tested |
| Host and simulator | 32 host tests, build, generated-card injected-provider controller replay | Passed within reported fixture limits; simulator Vision feature print unavailable |
| Real camera recognition | Nonempty completed single-image response received | Provider path passed; display/matching acceptance still open |
| Correct on-screen target | Real trial had matchedAtCompletion=false and no display; local repair under verification | In progress |
| Everyday usage | Live first-result/cache timing, near-identical products, backs, low light, battery/usage | Not accepted yet |

The product is personal and iPhone-only. All readable names, text and barcode values appear together at the bottom, without recognition modes or online product lookup. Waiting and empty results stay silent. Camera frames remain local until a stable-target single JPEG request; images are not persisted. Backgrounding clears memory and cancels work. Late results cannot attach to a different target.

The official account catalog must expose the chosen model; this project's tested account exposed `gpt-6-luna`, and image input with `reasoning.effort=none` completed. No separate API billing or borrowed-token fallback is allowed. Official Usage settings govern extra credits; a local confirmation checkbox is only an attestation.

History: [external browser and system-window probes](PHASE_A.md), [formal sign-in and SSE fixes](PHASE_B.md), [current camera work](PHASE_C.md), [next steps](NEXT_STEPS.md).
