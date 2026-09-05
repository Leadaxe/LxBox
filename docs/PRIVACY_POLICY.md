# Privacy Policy

**Application:** L×Box (`com.leadaxe.lxbox`)
**Last updated:** 14 August 2026

> Русская версия: [PRIVACY_POLICY.ru.md](PRIVACY_POLICY.ru.md)

## Summary

L×Box is a VPN and proxy client. It does not have user accounts, does not
contain analytics or advertising SDKs, and does not send your browsing activity
anywhere.

The developer operates no servers that carry your traffic. Every server L×Box
connects to is one **you** added. Your traffic goes to those servers under
whatever terms their operator sets — the developer has no visibility into it.

## What the app stores on your device

All application data stays on your device:

* Servers, subscriptions and their cached contents
* Routing rules, DNS settings, per-app selections
* Connection statistics and logs
* WireGuard/WARP keys, when you use that feature

None of it is transmitted to the developer. Uninstalling the app removes it. You
can export a backup yourself; that file goes wherever you send it.

## Network requests the app makes on its own

Two automatic requests, both plain HTTP GET with no request body:

| Endpoint | Purpose | Frequency |
|---|---|---|
| `api.github.com` | Check whether a newer release exists | At most once per 24 hours |
| `raw.githubusercontent.com` | Fetch the support feed, donation options and the public-server manifest | On launch, cached |

These send the application version in the `User-Agent` header. As with any
network request, the receiving server sees your IP address. Both endpoints
belong to GitHub and are covered by
[GitHub's Privacy Statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement).

## Network requests you trigger

**Subscription updates.** L×Box fetches the URLs you added. The request carries
a `User-Agent` header. Optionally — **off by default** — it can also carry an
identifier some subscription providers require:

* `x-hwid` — a randomly generated UUID, not a hardware identifier. You can view
  and replace it.
* Device model and OS version. Both can be overridden with any value you like.

You enable this yourself, per subscription or globally, and the values are
yours to edit. Nothing is sent when it is off.

**Cloudflare WARP registration.** If you use *Get WARP*, the app registers a
tunnel with Cloudflare's device API — `api.devices.cloudflare.com`, or
`api.cloudflareclient.com` when the first host is unreachable. The WireGuard private key is generated
on your device and never leaves it — only the **public** key is transmitted. The
request reports a fixed placeholder device model (`PC`), the platform name
(`Android`) and a fixed locale (`en_US`) rather than your real device details,
and the installation and push-token fields are sent empty. Cloudflare's handling of this request is governed by the
[Cloudflare Privacy Policy](https://www.cloudflare.com/privacypolicy/).

**Rule-set downloads.** Files fetched from URLs you configure. These can also
refresh on a schedule once you enable automatic updates for them.

**Connectivity probes.** When automatic server selection is on, the core
periodically requests a small test page (by default
`cp.cloudflare.com/generate_204`, every 15 minutes) to find out which of your
servers still responds. The probe travels **through the server being tested**,
so the endpoint sees that server's address rather than yours. The URL and the
interval are yours to change.

**Node diagnostics.** The *Diagnostics* screen sends a single GET through a
chosen server to a preset address (for example `ipinfo.io`) so you can see what
that server's exit looks like from outside. It runs only when you press the
button, and the response is shown to you verbatim.

**Speed tests.** A test file is downloaded from the endpoint you select to
measure throughput.

## Permissions

| Permission | Why | Leaves the device? |
|---|---|---|
| Internet, network state | Connect to servers, detect network changes | — |
| Location (incl. background) | Android only reveals the Wi-Fi network name (SSID) to apps holding a location permission. The SSID is used to match routing rules you write, such as "on my home network, bypass the tunnel". The tunnel runs as a foreground service and evaluates rules with the screen off, which is why the background variant is required. | **No.** Coordinates are never requested, stored or transmitted. |
| Camera | Scanning configuration QR codes | **No.** Decoding happens on device. |
| Installed applications | Per-app routing: choosing which apps use the tunnel | **No.** The list stays on the device. |
| Notifications | Showing tunnel status | — |
| Run at startup, ignore battery optimisation | Optional auto-start and keeping the tunnel alive | — |

## What the app does not do

* No account, registration or login
* No analytics, telemetry or crash reporting services
* No advertising SDKs, and no use of the Advertising ID
* No collection of browsing history, visited domains or traffic contents
* No sale or sharing of personal data — none is collected to begin with

Crash logs are written to local storage. They are shared only if you explicitly
choose to send them, using the system share dialog, to a destination you pick.

## Children

L×Box is not directed at children and collects no data from anyone, including
children.

## Third parties

The developer shares nothing, because nothing is collected. Requests you or the
app make reach the operators of those endpoints — GitHub, Cloudflare, and the
subscription and rule-set providers you configured — each under its own terms.

## Source code

L×Box is free software under the GNU General Public License v3. The complete
source is public, so every statement here can be verified:
<https://github.com/Leadaxe/LxBox>

## Changes

Material changes to this policy will be published in this file; its history is
visible in the repository's commit log.

## Contact

Questions about this policy: [leadaxe@gmail.com](mailto:leadaxe@gmail.com)
Issues: <https://github.com/Leadaxe/LxBox/issues>
