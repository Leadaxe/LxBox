# §395 — background update check only for GitHub sideloads

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

Catalogue users lose nothing: the F-Droid client already tells them about new
versions. Sideload users have no such client, so for them the check stays.

## What the flag is not

Not a `--dart-define`. Any define lands inside the compiled Dart code, so the
GitHub APK (built without it) and the F-Droid APK (built with it) would differ
byte for byte — and `binary:` verification would fail. That is §390's rule, and
it holds here.

The channel is resolved at runtime instead, from `installingPackageName`, which
the system writes at install time and the app cannot forge.

## Flow

```
                    app launch
                        │
                        ▼
        InstallSourceResolver.init()      ← §390, before runApp
        reads installingPackageName
                        │
        ┌───────────────┼───────────────┐
        ▼               ▼               ▼
  org.fdroid.*   com.android.vending   null / browser
        │               │               │
     fdroid            play           github
        └───────┬───────┘               │
                ▼                       ▼
      autoCheckSupported=false   autoCheckSupported=true
                │                       │
                ▼                       ▼
   ┌────────────────────────┐  ┌────────────────────────┐
   │ HomeScreen             │  │ HomeScreen             │
   │  · no 5s timer         │  │  · 5s timer armed      │
   │  · no cache snackbar   │  │  · snackbar from cache │
   │ Settings › Updates     │  │ Settings › Updates     │
   │  · toggle hidden       │  │  · toggle shown        │
   │  · "Check now" shown   │  │  · "Check now" shown   │
   └────────────────────────┘  └────────────────────────┘
                │                       │
                ▼                       ▼
        no network on its own    api.github.com, ≤1×/24h
```

`forceCheck` — the "Check now" button — stays on every channel. An explicit tap
is not background tracking, and without it the app could never tell the user a
release exists.

## Changes

| File | Change |
|---|---|
| `services/update_checker.dart` | `autoCheckSupported` getter; early return in `maybeCheck` |
| `screens/home_screen.dart` | 5s timer armed only when supported; `_hydrateAndMaybeNotify` returns early |
| `screens/app_settings_screen/widgets/general_tab.dart` | toggle wrapped in `if (UpdateChecker.autoCheckSupported)` |

`auto_check_updates` in storage is untouched: the value survives, it is simply
not read on catalogue installs. A user who sideloads over an F-Droid install
gets their old preference back.

## Behaviour

| Installed from | Auto check | Toggle | "Check now" |
|---|---|---|---|
| GitHub (sideload) | yes, ≤1×/24h | shown | works |
| F-Droid | **no** | **hidden** | works |
| Google Play | **no** | **hidden** | works |

## Verification

- [x] `flutter analyze` — clean
- [x] Device: install from GitHub → toggle visible, check fires
- [x] Device: install via F-Droid client → toggle absent, no request to
      `api.github.com` in the traffic log
- [ ] Reproducibility holds: no new `--dart-define`, so `binary:` still matches
      — confirmed by the next F-Droid run, not on device

## Open question for the reviewer

`linsui` asked to *remove* the checker, not to gate it. This change makes the
F-Droid build never reach out on its own, which is what the anti-feature rule
is about — but the code path still exists for sideloads. If that is not enough,
the fallback is to drop the checker entirely and let sideload users find
releases by themselves.

Related: [§390](390-install-source-aware-update-notice.md) — install-source
resolution and why build-time defines are banned from the recipe.
