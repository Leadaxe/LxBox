[English](AI_ASSISTANT.md) · [Русский](AI_ASSISTANT.ru.md)

# L×Box — AI assistants and your network

L×Box gives an AI assistant a set of functions: check why an address does
not open, read and change routing, turn a connection on or off. You say what
you need; the assistant picks the functions and calls them. This page
describes what the assistant gets, how to allow it, what to say, and how to
use the same functions from a computer through the Debug API.

## Contents

- [Two ways in](#two-ways-in)
- [Allow an assistant on the device](#allow-an-assistant-on-the-device)
- [Why a site or an app does not open](#why-a-site-or-an-app-does-not-open)
- [Send an app through an exit or a country](#send-an-app-through-an-exit-or-a-country)
- [Connect a work network](#connect-a-work-network)
- [What the assistant receives](#what-the-assistant-receives)
- [What the assistant cannot do](#what-the-assistant-cannot-do)
- [When L×Box is not open](#when-lbox-is-not-open)
- [The same from a computer: Debug API](#the-same-from-a-computer-debug-api)
- [Function reference](#function-reference)

---

## Two ways in

| Who calls | How | What it needs |
|---|---|---|
| An assistant on the device | Android AppFunctions: the system shows the assistant the functions L×Box declares | Android 16 or newer, an assistant that Android allows to call app functions, the **AI assistant control** switch |
| An agent on a computer | [Debug API](ADVANCED_USER_GUIDE.md#debug-api) over `adb forward` | USB debugging, the **Debug API** switch and its token |

Both reach the same code. An agent on a computer works on any supported
Android version and does not depend on a system assistant.

> ⚠️ AppFunctions is an experimental Android API. Google lets only the
> assistants of its early access programme call app functions, so on most
> devices a voice request does not reach L×Box yet. The Debug API path works
> regardless. The `adb shell cmd app_function` check needs a system image
> that ships the command: the Android 16 emulator image has it from API 36.1,
> the 36.0 image does not.

## Allow an assistant on the device

Two switches control what an assistant on the device may do. Both are off by
default.

Where to find them: App Settings → Automation → AI assistants. The section is
shown on Android 16 and newer.

| Switch | What it opens |
|---|---|
| **AI assistant control** | Starting and stopping the VPN, reading its status, network checks, the list of exits, switching the exit, reading rules, Directions and sources |
| **Let assistants change settings** | Adding, editing and deleting routing rules and Directions, turning sources and connections on or off, changing the default route and the list of tunnel apps |

The second switch works only while the first is on. With it on, the assistant
changes settings at once, without a confirmation for each change. With it off,
a request to change settings returns an error that names this switch.

Starting the VPN needs the Android VPN permission. L×Box gets it the first
time you press Start in the app; an assistant cannot grant it.

## Why a site or an app does not open

Say it as you would to a person:

- “Why doesn't example.com open?”
- “The Example Chat app can't connect — check it.”
- “Is my VPN working? What is my IP now?”

The assistant runs the address check — the same URL Check as in
Diagnostics → URL Check. The core walks the request through its stages and
reports where it stopped. If you name an app, the check follows the rules
that apply to that app.

| Stage in the answer | What failed | What usually helps |
|---|---|---|
| `dns` | The name did not resolve | Another DNS server or another exit |
| `route` | A rule blocked the address, or no route was chosen | Look at the rule the answer names |
| `tunnel`, `connect` | The exit server or the site did not respond | Another exit |
| `tls` | The secure handshake was refused | Another exit or a direct route |
| `http` | The site answered with an error code | The network path works; the site itself refuses |

The answer also names the Direction and the exit the request went through,
or says that it went directly or was blocked, and carries a short piece of
advice.

The check runs only while the VPN is on. With the VPN off the assistant gets
`vpn_off`; the check does not start the VPN by itself.

The exit check answers “which country do I come out in”: it makes a request
through a Direction to `1.1.1.1/cdn-cgi/trace` and returns the external IP
address and the country code.

## Send an app through an exit or a country

- “Send Example Chat through Germany.”
- “Example Chat must use vpn-1 only on my Home Wi-Fi.”
- “Send the Example Bank app directly, past the VPN.”
- “Switch my main Direction to a server in the Netherlands.”

A Direction is a group of exits (servers) that rules send traffic to. L×Box
does not store a server's country. The assistant reads the names of the exits
— providers put a flag or a country name there — and decides which of them
match your request. After a change it can run the exit check and compare the
country code with what you asked for.

What the assistant does for “send Example Chat through Germany”:

1. finds the app's package name by its title;
2. reads the exits of a Direction and picks the German ones by name;
3. creates a Direction limited to those exits and a rule “this app → this
   Direction”, then reloads the tunnel;
4. runs the exit check on the new Direction.

A rule may carry any conditions the rule editor has: apps, Wi-Fi networks,
network type, domains, IP ranges, ports.

Two kinds of change differ:

- **Switching the exit inside a Direction** affects every rule that points to
  this Direction and lasts until the tunnel restarts. It needs only **AI
  assistant control**.
- **A rule or a new Direction** is saved in the settings and stays. It needs
  **Let assistants change settings**.

A Direction with automatic choice of the best server does not accept a manual
exit.

> ⚠️ The exit's name is written by the subscription provider. A flag in the
> name is not a guarantee of the country; the exit check shows the country
> the traffic actually leaves from.

## Connect a work network

- “Connect me to the work network.”
- “Turn off the office WireGuard.”
- “Is Tailscale connected?”

Connections here are the servers of five types: WireGuard, AmneziaWG,
OpenVPN, OpenConnect and Tailscale. The assistant sees their list with the
name, the type, whether each is turned on, and the state:

| State | Meaning |
|---|---|
| `up` | Connected |
| `connecting` | Being established |
| `idle` | A WireGuard tunnel suspended while unused; it wakes on traffic |
| `needs_login` | Sign-in is required in the app |
| `down` | Not connected, or the VPN is off |
| `disabled` | Turned off in the list of servers |
| `unknown` | The state is not reported; always so for OpenVPN |

Turning a connection on sets its switch in the list of servers, rebuilds the
config and reloads the tunnel. If the VPN was off, L×Box starts it, provided
the VPN permission has been granted. Turning a connection off does not stop
the VPN.

A connection inside a folder or a subscription that is itself turned off is
not turned on: the assistant gets an error that names the reason.

Sign-in to OpenConnect or Tailscale stays in the app: the assistant does not
enter passwords or codes.

## What the assistant receives

- Names: exits (servers), Directions, connections, apps and rules. Server
  names come from your subscription provider as they are.
- Routing rules and Directions with their conditions, the list of sources
  with their state.
- The result of a check: the failed stage, the core's error text, the HTTP
  code, the exit. The exit check returns the external IP address and the
  country code.
- The list of installed apps that match a search by title.

The assistant does not receive: the config file, server addresses and keys,
subscription links, backups, logs.

What the assistant does with this data is governed by the assistant's own
privacy terms, not by L×Box. L×Box itself sends this data nowhere.

## What the assistant cannot do

- Add or delete servers, subscriptions and folders.
- Change DNS settings, mixins and the config file.
- Change the tunnel's security switches and the Debug API settings.
- Turn on **AI assistant control** or **Let assistants change settings**.
- Grant the VPN permission or sign in to a connection.
- Export a backup, read logs or files.

A request for any of this returns an error; nothing is changed.

## When L×Box is not open

Part of the functions runs without the app's window: starting and stopping
the VPN, its status, the address check, the exit check, the list of exits,
switching the exit, the app search.

Everything that reads or changes the settings — rules, Directions, sources,
the network overview — needs the app's window. If L×Box is not open, it tries
to open its window and then carries out the request. If Android does not
allow a window to be opened from the background, the assistant gets the error
“L×Box is not open. Open the app and repeat.” and a notification appears;
tapping it opens the app.

## The same from a computer: Debug API

An agent on a computer — a coding assistant with a terminal, a script — calls
the same functions over HTTP. The Debug API does not ask the two assistant
switches: its own switch and token are the permission. What the Debug API is,
its switch, token and port:
[Advanced user guide → Debug API](ADVANCED_USER_GUIDE.md#debug-api); every
route with examples: [Debug API reference](api/debug-api-reference.md).

1. On the device: App Settings → Diagnostics → Developer → **Debug API**,
   then copy the token.
2. On the computer:

```bash
adb forward tcp:9269 tcp:9269
TOK="<token>"
BASE="http://127.0.0.1:9269"
HDR="Authorization: Bearer $TOK"
```

Why an address does not open:

```bash
curl -s -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"url":"https://example.com","app":"org.example.chat"}' \
  "$BASE/assistant/check-url"
```

An app through chosen exits, only on one Wi-Fi network:

```bash
curl -s -H "$HDR" "$BASE/assistant/apps?q=chat"
curl -s -H "$HDR" "$BASE/assistant/exits?direction=vpn-1&q=germany"
curl -s -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"label":"Germany","node_filter":"Germany","auto":{}}' "$BASE/directions"
curl -s -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"kind":"inline","name":"Chat at home","packages":["org.example.chat"],"wifi_ssids":["Home"],"outbound":"vpn-2"}' \
  "$BASE/rules?rebuild=true"
curl -s -X POST -H "$HDR" "$BASE/action/reload-vpn"
curl -s -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"direction":"vpn-2"}' "$BASE/assistant/check-exit"
```

A work connection:

```bash
curl -s -H "$HDR" "$BASE/assistant/overview"
curl -s -X POST -H "$HDR" -H "Content-Type: application/json" \
  -d '{"id":"Office","enabled":true}' "$BASE/assistant/connection"
```

Reference sections for the routes used above:

| Routes | Section |
|---|---|
| `/assistant/*` — overview, exits, checks, app search, connections | [Assistant](api/debug-api-reference.md#assistant--assistant-750) |
| `/rules/*` — routing rules and their conditions | [Rules CRUD](api/debug-api-reference.md#rules-crud--rules) |
| `/directions/*` — Directions and their exit filter | [Directions CRUD](api/debug-api-reference.md#directions-crud--directions) |
| `/subs/*`, `/folders/*` — sources | [Subscriptions CRUD](api/debug-api-reference.md#subscriptions-crud--subs), [Folders CRUD](api/debug-api-reference.md#folders-crud--folders) |
| `/action/*` — start, stop and reload the VPN, switch a server | [Actions](api/debug-api-reference.md#actions--триггеры) |
| `/state` — the current state | [State & introspection](api/debug-api-reference.md#state--introspection) |
| Error codes | [Common errors](api/debug-api-reference.md#common-errors) |

Setup and the security model of the Debug API:
[Setup](api/debug-api-reference.md#setup-one-time),
[Security model](api/debug-api-reference.md#security-model--root-доступ-by-design).

## Function reference

Functions an assistant on the device gets:

| Function | What it does | Needs the app's window |
|---|---|---|
| `startVpn`, `stopVpn`, `getVpnStatus` | Start, stop, status of the VPN | no |
| `checkUrl` | The address check by stages | no |
| `checkExit` | The external IP address and country of a Direction's exit | no |
| `listExits` | Names of a Direction's exits, with a search by substring | no |
| `selectExit` | Switch the exit inside a Direction | no |
| `findApps` | Find an installed app by title | no |
| `getApiHelp` | The list of routes available through `callApi` | yes |
| `callApi` | Call a route: overview, rules, Directions, sources, connections | yes |

`callApi` reaches a part of the Debug API routes: the sections
[Assistant](api/debug-api-reference.md#assistant--assistant-750), [Rules](api/debug-api-reference.md#rules-crud--rules),
[Directions](api/debug-api-reference.md#directions-crud--directions), reading and switching sources,
and the VPN actions. `getApiHelp` returns the exact list.

A check without an assistant, on a device whose system has the command
(`adb shell cmd app_function help` prints the list):

```bash
adb shell cmd app_function list-app-functions --package com.leadaxe.lxbox
adb shell cmd app_function execute-app-function --package com.leadaxe.lxbox \
  --function 'com.leadaxe.lxbox.appfunctions.LxBoxAppFunctions#checkUrl' \
  --parameters '{"url":"https://example.com"}'
```

Technical details of the AppFunctions declaration:
[Automation → AI assistants](AUTOMATION.md#ai-assistants-appfunctions).
