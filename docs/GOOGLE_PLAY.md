# Publishing on Google Play

Related: [`RELEASE_PROCESS.md`](RELEASE_PROCESS.md), [`FDROID.md`](FDROID.md), [`BUILD.md`](BUILD.md).

| What | Where |
|---|---|
| Package | `com.leadaxe.lxbox` |
| Developer account | `leadaxe` (personal; migration to an organization account is pending a D-U-N-S number) |
| Console mail | `lxboxvpnclient@gmail.com`, `leadaxe@gmail.com` |
| Artifact | AAB — `flutter build appbundle`, see [`BUILD.md`](BUILD.md); uploaded by CI, see [CI upload](#ci-upload) |
| Store listing | `fastlane/metadata/android/{en-US,ru}/`, shared with F-Droid |

Unlike F-Droid, Google Play does not build from source: an AAB signed with our
upload key is uploaded, and Play re-signs it with the app signing key. The same
source tree produces the GitHub, F-Droid and Play builds; the AAB is the one
artifact built with `--dart-define=LXBOX_DISTRIBUTION=play` (the CI AAB step
only, §390), while the APKs carry no define and detect the install channel at
runtime from `installingPackageName` — see [BUILD.md](BUILD.md#the-flutter-app)
and [RELEASE_PROCESS.md](RELEASE_PROCESS.md) on why the APKs must stay
define-free (F-Droid's byte comparison).

## Milestones

| Date | What |
|---|---|
| 2026-08-08 … 08-12 | Closed testing group signed up — 30 testers, see [Testers](#testers) |
| 2026-08-28 | Production access granted; closed testing requirements met |
| 2026-09-04 | IARC age rating live. Global Rating ID `1287b51d-d8a5-84b4-8420-3f8ac03cebb6` |

The IARC rating ID is reusable: any other store under an IARC licence
(Microsoft Store, Nintendo, …) takes the same ID instead of a new
questionnaire. Fill the questionnaire again only when an update changes what
the answers were based on — user-generated content, chat, or payments.

## Closed testing

Google requires a closed test with a group of testers before production access
is granted. Testers opt in through a link, install the build from Play, and
keep it on a personal device for the whole test period.

| What | Value |
|---|---|
| Opt-in link | `play.google.com/apps/testing/com.leadaxe.lxbox` |
| Group size | 30 testers |
| Recruiting | A form on 4PDA and in the project channels |
| Outcome | Production access granted 2026-08-28 |

Participants who asked for one received a personal certificate of
participation; the template and its generator live in
[`design/certificate/`](design/certificate/).

## Testers

Closed testing is the one step that cannot be done alone — Google wants real
people on real devices, and thirty of them showed up. Thank you.

Listed below are the testers who agreed to be named. Everyone else took part
just as much; they simply preferred not to be listed.

| | | |
|---|---|---|
| Tayaere | 9ghtX | Wildgraf |
| AlexxD | Aiurat | Игорь Борисов |
| bogggi | Дмитрий Орлов | akella111 |
| Сергей | Юляша | Алёна |
| ginger | Яша! | MaxInNotion |

## Per release

1. Bump the version, tag, and let CI produce the AAB (see
   [`RELEASE_PROCESS.md`](RELEASE_PROCESS.md)).
2. CI uploads the AAB to the `PLAY_TRACK` track (see [CI upload](#ci-upload));
   with `PLAY_RELEASE_STATUS=draft` open the console and press Publish.
3. Changelog per locale goes into
   `fastlane/metadata/android/<locale>/changelogs/<versionCode>.txt`, ≤ 500
   characters — the same files F-Droid reads.
4. Screenshots must not show the Servers screen with personal subscriptions;
   use servers from `public-servers-manifest.json`.

## CI upload

Since §436 the `google-play` job (shown as “GooglePlay”) in [`ci.yml`](../.github/workflows/ci.yml) uploads
the AAB on every release tag through the Google Play Developer API. What it
needs and where it lives:

| What | Where |
|---|---|
| Identity | a service account in the owner's Google Cloud project ("LxBox CI", Google Play Android Developer API enabled); its e-mail is the `client_email` field of the key |
| Play Console access | Users and permissions → the account is invited on L×Box with "Release to production, exclude devices, and use Play App Signing" and "Release apps to testing tracks"; nothing else |
| Key | repository secret `PLAY_SERVICE_ACCOUNT_JSON`, the JSON key as is: `gh secret set PLAY_SERVICE_ACCOUNT_JSON < .keys/google-play-publisher.json`. The local copy lives in `.keys/`, which is git-ignored |
| Track | repository variable `PLAY_TRACK`, default `production`; for a release candidate `PLAY_RC_TRACK`, default `beta` (Open testing). The job's `target` step picks the pair by `is_prerelease` and logs `track=… status=…` |
| Which tags | every release tag. Releases `vX.Y.Z` and hotfixes `vX.Y.Z-hotfixN` go to `PLAY_TRACK`; release candidates `vX.Y.Z-rc.N` (job `meta` sets `is_prerelease`) go to Open testing (§619). Open testing passes Google's review just like production, and the Open testing page (countries, testers) must be set up in the console first, otherwise the API rejects the track. A candidate's code (PRE 01–49) is below the release of the same version, so the codes never collide |
| Release status | repository variable `PLAY_RELEASE_STATUS`. The repository is set to `completed`: the release goes to Google's review by itself and is published once approved (requires Managed publishing to be off in the console). The YAML fallback is `draft` — delete the variable and the release lands as a draft for a human to publish |
| Release candidate status | repository variable `PLAY_RC_RELEASE_STATUS`, default `completed`: the candidate goes to Google's review by itself and reaches open testers once approved |
| Release notes | `fastlane/metadata/android/{en-US,ru}/changelogs/<versionCode>.txt` → Play locales `en-US`, `ru-RU`. The AAB carries the universal code (…0) while the files are named by the per-ABI codes (…1/…2), so the job takes the first of …0/…2/…1/…4 it finds. A release candidate with no file under its own code falls back to the release code of the same version (PRE=50); the log names the file taken. Over 500 characters fails the `checks` job on push |
| Action | `r0adkll/upload-google-play`, pinned by commit — it receives the key |

`release` and `publish-manifest` do not depend on `google-play`: a failed upload
leaves the GitHub release intact, and the AAB stays in the run's
`android-aab-release` artifact for a manual upload. Without the secret the job
logs a warning and skips, so forks build as before. Failure modes are in
[`RELEASE_PROCESS.md`](RELEASE_PROCESS.md#the-google-play-job-is-red).

## Gotchas

| What | Why |
|---|---|
| VPN apps get extra review | Play treats `VpnService` as a sensitive permission. The listing must state plainly what the app does with traffic; see [`PRIVACY_POLICY.md`](PRIVACY_POLICY.md) |
| The Play badge is licensed narrowly | The "Get it on Google Play" badge may be used to link to the app, unmodified. It may not be used to imply that Google endorses or certifies anything — see the note in [`design/certificate/README.md`](design/certificate/README.md) |
| Personal → organization account | Play now requires an organization account for most new developers; the migration needs a D-U-N-S number, which is issued separately and takes weeks |
