# §395 — ask before checking for updates

## Why

The F-Droid reviewer blocked [MR!44731](https://gitlab.com/fdroid/fdroiddata/-/merge_requests/44731):

> Review result: BLOCKED. The F-Droid recipe has no Tracking declaration, but
> the pinned source starts `UpdateChecker.maybeCheck()` five seconds after
> HomeScreen startup. It polls GitHub Releases and `auto_check_updates`
> defaults to true.
> — andrewpozdnakov7, 14.08.2026

`linsui` followed with a one-liner: *"Please remove the update checker."*

The finding is accurate. The app reached `api.github.com` on its own, five
seconds into every launch, without the user asking for it. By F-Droid's rules
that is the `Tracking` anti-feature — an app phoning the developer's server and
exposing the user's IP to a third party.

### First attempt, and why it was not enough

v2.20.9 gated the check on `installingPackageName`: installed by an F-Droid
client → never check. `linsui` pushed back the same day:

> There are many other F-Droid clients. You can add an onboarding screen for
> the update checker.

He is right. The gate knew `org.fdroid.fdroid`, `org.fdroid.basic` and
`com.looker.droidify`; Neo Store, F-Droid Classic, Aurora and whatever ships
next would have fallen through to `github` and switched the check back on.
Chasing that list forever is the wrong shape of solution.

So the gate is gone. The app asks instead, once, on first run. Explicit consent
is what the anti-feature rule is actually about, and it holds no matter which
client installed the app.

## Not a build flag

A `--dart-define` would land inside the compiled Dart code: the GitHub APK
(built without it) and the F-Droid APK (built with it) would differ byte for
byte, and `binary:` verification would fail. That is §390's rule and it still
holds — nothing here is decided at build time.

## Flow

```
                       first run
                           │
                           ▼
                   StartupWizard.run()
                           │
      1. notification permission ──┐
      2. battery optimization      │  existing steps,
      3. add QS tile               │  each with its own flag
                           │ ──────┘
                           ▼
      4. maybeShowUpdateCheckPrompt()      ← §395
                           │
              already asked? ── yes ──▶ skip
                           │ no
                           ▼
              ┌────────────────────────────┐
              │  Check for updates?        │
              │                            │
              │  pings github.com once a   │
              │  day · nothing installs    │
              │  by itself                 │
              │                            │
              │      [ Skip ]  [ Enable ]  │
              └────────────────────────────┘
                     │              │
                     ▼              ▼
       auto_check_updates=false   =true
                     │              │
                     ▼              ▼
            no network on      api.github.com,
            its own, ever      ≤1×/24h

   back button → default by install source:
     from a store client → Skip · sideload → Enable
```

The install source survives only as that default. Getting it wrong is now
harmless — the user's answer overrides it either way.

`forceCheck` — the "Check now" button in settings — is untouched and works
everywhere. An explicit tap is not background tracking.

## Changes

| File | Change |
|---|---|
| `screens/home/home_dialogs.dart` | `maybeShowUpdateCheckPrompt` — the dialog, flag `wizard_update_check_v1` |
| `screens/home/startup_wizard.dart` | step 4, after the tile prompt |
| `services/settings_storage.dart` | `auto_check_updates` default flipped to `false` |
| `services/update_checker.dart` | `autoCheckSupported` removed |
| `screens/home_screen.dart` | gate removed — the 5s timer is armed again for everyone |
| `screens/app_settings_screen/widgets/general_tab.dart` | toggle visible on every channel again |

The storage default is the load-bearing part: until the user answers, the app
does not reach out. Existing installs that already said yes keep their value —
the key is only written by the prompt.

## Behaviour

| | Auto check | Toggle | "Check now" |
|---|---|---|---|
| Answered "Enable" | yes, ≤1×/24h | shown | works |
| Answered "Skip" | no | shown, off | works |
| Not asked yet | no | shown, off | works |

Dev builds skip the prompt: `_isDevBuild` already silences the checker, so the
question would be noise.

## Verification

- [x] `flutter analyze` — clean
- [x] `flutter test` — 3016 passed
- [x] l10n checkers — template / ui / hardcoded / kotlin, all strict
- [ ] Device: first run shows the prompt once, answer persists
- [ ] Device: "Skip" → no request to `api.github.com` in the traffic log
- [ ] Reproducibility holds — confirmed by the next F-Droid run

Related: [§390](390-install-source-aware-update-notice.md) — install-source
resolution and why build-time defines are banned from the recipe.
