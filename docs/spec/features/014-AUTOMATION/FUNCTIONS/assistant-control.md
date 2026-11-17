[English](assistant-control.md) · [Русский](assistant-control.ru.md)

# Assistant control — an AI assistant diagnoses and manages the network

Off by default; the user turns it on.

| Field | Value |
|-------|-------|
| Feature | [014-AUTOMATION](../FEATURE.md) |
| Promises | P15 |
| State | ✅ written from the spec of task 750, 2026-11-17; not verified on a device |

## What it does

Gives an AI assistant a set of functions so that a request in plain words is
carried out by the app: find out why an address does not open, send an app
through a chosen exit, connect or disconnect a work network. The assistant
decides which functions to call and in what order; the app only executes
them and answers with data.

## Parameters

| Parameter | Values / behaviour |
|-----------|--------------------|
| App Settings → Automation → AI assistants → **AI assistant control** | on/off, off by default; opens every function |
| App Settings → Automation → AI assistants → **Let assistants change settings** | on/off, off by default; works only with the first one; opens changes to saved settings |

Both are shown on Android 16 and newer and travel in the backup.

## Inputs / Outputs

**Inputs:** a function call from an assistant; the two toggles; tunnel
status; the saved settings; the VPN permission.

**Outputs:** tunnel start or stop; the result of an address check (failed
stage, error, HTTP code, the Direction and exit used, advice); the external
address and country of an exit; names of a Direction's exits; a chosen exit;
installed apps matching a search; rules, Directions, sources and connections
with their state; changed rules, Directions and switches of sources.

| Group | Examples | Toggle |
|-------|----------|--------|
| Tunnel | start, stop, status | AI assistant control |
| Checks | address check, exit check | AI assistant control |
| Reading | exits, apps, rules, Directions, sources, connections | AI assistant control |
| Choice in the running tunnel | switch the exit of a Direction | AI assistant control |
| Changes to saved settings | add or edit a rule or a Direction, turn a source or a connection on or off, default route, tunnel apps | Let assistants change settings |

## Rules and invariants

- With "AI assistant control" off no function is executed; the assistant
  gets an error.
- With "Let assistants change settings" off a change is refused with a text
  that names the toggle; nothing is changed.
- A change is applied at once, without a confirmation for each one.
- The app does not interpret exit names: the country of an exit is judged by
  the assistant from the name, and confirmed by the exit check.
- An address check and an exit check run only while the tunnel is up; they
  never start the tunnel.
- Starting the tunnel needs a VPN permission granted earlier; the assistant
  cannot grant it.
- Tunnel functions, the checks, the list of exits, switching the exit and
  the app search work without the app's window. Reading and changing the
  settings need the window: the app tries to open it; if the OS refuses, the
  assistant gets an error and the user gets a notification.
- Nothing is computed in advance for the assistant: the app does no extra
  work on start or on a settings change while no function is called.
- Texts of advice and errors come from the app's own tables.

## Boundaries

- Never given to an assistant: the config, server addresses and keys,
  subscription links, backups, logs, files.
- An assistant cannot add or delete servers, subscriptions and folders,
  change DNS settings, mixins, the config, the tunnel's security switches,
  the Debug API settings or its own two toggles.
- Sign-in to a connection stays in the app.
- The state of an OpenVPN connection is not reported.
- Depends on the OS: functions for assistants exist on Android 16 and newer,
  and the OS decides which assistants may call them.
- The same functions for an agent on a computer —
  [027-DEBUG_API](../../027-DEBUG_API/FEATURE.md).

## Revisions

| # | Revision | Status | Summary |
|---|----------|--------|---------|
| 1 | [721](../../../tasks/721-appfunctions-vpn-toggle-status.md) | Done (v2.25.21), not verified on a device | Start, stop and status of the tunnel for assistants; the "AI assistant control" toggle |
| 2 | [750](../../../tasks/750-ai-assistant-network-control.md) | In progress, not verified on a device | Checks, exits, app search, the gateway to routing, sources and connections; the "Let assistants change settings" toggle |
