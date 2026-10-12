# sora-editor assets

Assets for the native code editor behind every JSON field of the app
(`SoraEditorPlatformView.kt`, Dart side `lib/widgets/lx_code_editor.dart`).

| File | Source | License |
|---|---|---|
| `json.tmLanguage.json` | microsoft/vscode, `extensions/json/syntaxes/JSON.tmLanguage.json` (branch `main`, fetched 2026-10-11), converted by Microsoft from `microsoft/vscode-JSON.tmLanguage` | MIT, Copyright (c) Microsoft Corporation — full text in `LICENSE-vscode.txt` |
| `ini.tmLanguage.json` | microsoft/vscode, `extensions/ini/syntaxes/ini.tmLanguage.json`, commit `cc3fec8846d0e678357e476fa611774da26d7e24` (last change to the file: `8fdf170a0850c1cc027382f31650aaf300d3ae2a`), converted by Microsoft from `textmate/ini.tmbundle` | MIT, Copyright (c) Microsoft Corporation — full text in `LICENSE-vscode.txt` |
| `uri.tmLanguage.json` | written for LxBox: proxy links one per line (scheme, userinfo, host, port, query, fragment); colors what it recognizes, never validates | same as the app |
| `json.language-configuration.json` | written for LxBox: comments and brackets, so the editor builds code blocks for sticky headers | same as the app |
| `lx-light.json`, `lx-dark.json` | written for LxBox (VS Code theme format; only token colors matter — background, text, line numbers, selection and caret come from the app `ColorScheme`) | same as the app |

The editor itself is `io.github.Rosemoe.sora-editor` (LGPL-2.1), pulled from
Maven Central as a dynamically linked library; R8 keep rules are in
`app/android/app/proguard-sora.pro`.
