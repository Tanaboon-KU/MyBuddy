<p align="center">
  <img src="assets/logo.png" alt="MyBuddy Logo" width="120" />
</p>

<h1 align="center">MyBuddy</h1>

<p align="center">
  <strong>A privacy-first AI companion with on-device LLM, voice interaction, an embedded 3D avatar, and an Android floating overlay - built with Flutter.</strong>
</p>

<p align="center">
  <a href="#overview">Overview</a> &bull;
  <a href="#related-repositories">Related Repositories</a> &bull;
  <a href="#features">Features</a> &bull;
  <a href="#architecture">Architecture</a> &bull;
  <a href="#requirements">Requirements</a> &bull;
  <a href="#getting-started">Getting Started</a> &bull;
  <a href="#configuration">Configuration</a> &bull;
  <a href="#running-the-app">Running the App</a> &bull;
  <a href="#building-for-release">Building for Release</a> &bull;
  <a href="#troubleshooting">Troubleshooting</a> &bull;
  <a href="#license">License</a>
</p>

> This project uses FVM and is pinned to Flutter 3.41.6 in `.fvmrc`. Use `fvm flutter` for Flutter commands in this repository.

---

## Overview

MyBuddy is a local-first AI companion application that runs large language models and speech recognition on the user's device. The product combines:

- on-device LLM inference for text conversations and tool calling
- Whisper-based speech recognition for voice input
- platform TTS with WAV generation for avatar lip-sync
- an embedded Unity avatar on Android
- a floating Android overlay for multitasking
- structured long-term memory and Google Calendar integration

This repository contains the Flutter application and the local Flutter packages it depends on at runtime.

---

## Related Repositories

MyBuddy is part of a multi-repository product surface:

- **Flutter app**: [https://github.com/newnonsick/MyBuddy](https://github.com/Tanaboon-KU/MyBuddy)
- **Unity avatar runtime**: [https://github.com/newnonsick/MyBuddy-Unity](https://github.com/Tanaboon-KU/MyBuddy-Unity)
- **Model catalog admin panel**: [https://github.com/newnonsick/MyBuddy-Admin-Panel](https://github.com/Tanaboon-KU/MyBuddy-Admin-Panel)

The app consumes the Unity export as an Android library and fetches LLM and STT catalogs from the admin panel API at runtime.

---

## Features

### On-Device AI

- local LLM inference through `flutter_gemma`
- support for multiple model families such as Gemma, Qwen, DeepSeek, Llama, and Phi-class general models
- serialized inference pipeline to avoid unsafe concurrent model execution
- function calling for avatar animation and Google Calendar event creation

### Voice Interaction

- on-device speech-to-text via `whisper_ggml_plus`
- hold-to-record chat flow with automatic transcription submission
- text-to-speech output with WAV synthesis for avatar playback
- optional CoreML encoder downloads on Apple platforms for STT acceleration

### 3D Avatar and Overlay

- embedded Unity avatar rendered behind Flutter on Android
- lip-sync and animation playback driven by Flutter requests
- Android floating overlay with bidirectional IPC to the main app process
- multiple overlay presentation modes for multitasking

### Product Capabilities

- three-layer persistent memory: Soul, Identity, and User Profile
- Google Calendar integration with natural-language event creation
- model download and local model management from remote catalogs
- scheduled notifications with timezone-aware delivery

---

## Architecture

MyBuddy follows a feature-first Flutter architecture with a shared core services layer and Riverpod-managed application state.

```text
lib/
  app/        App-level controllers, providers, orchestration
  core/       Domain services, platform bridges, model and memory systems
  features/   Chat, settings, overlay, and calendar UI modules
  shared/     Reusable widgets and utilities

packages/
  whisper_ggml_plus/       Local Whisper.cpp Flutter plugin
  flutter_overlay_window/  Local Android overlay plugin

android/
  app/           Flutter Android host
  unityLibrary/  Exported Unity Android library embedded by the app
  launcher/      Unity-exported launcher module retained for compatibility
```

Key runtime boundaries:

- Flutter to Unity: `MethodChannel('unity_bridge')`
- App to overlay process: `BasicMessageChannel('x-slayer/overlay_messenger')`
- Remote model catalogs: JSON API served by the MyBuddy-Admin-Panel

---

## Requirements

### Core Tooling

- FVM installed locally
- Flutter SDK 3.41.6 via FVM
- Android Studio or Visual Studio Code with Flutter tooling
- JDK 11 for Android builds
- Android SDK and NDK `29.0.13113456`

### Platform Notes

- Android is the primary supported production target
- iOS, macOS, Windows, Linux, and Web folders exist, but the Unity avatar and Android overlay are Android-specific
- Apple STT acceleration requires Xcode and CoreML-capable devices

### Optional External Services

- Google Cloud project and OAuth credentials for Calendar integration
- network access for model catalog fetches and model downloads

---

## Getting Started

### 1. Clone the Repository

```bash
git clone https://github.com/newnonsick/MyBuddy.git
cd MyBuddy
```

### 2. Install the pinned Flutter SDK

```bash
fvm install
```

### 3. Install Flutter Dependencies

```bash
fvm flutter pub get
```

### 4. Prepare Android Tooling

Confirm that `android/local.properties` points to a valid Android SDK and the FVM-managed Flutter SDK. The Android project expects:

- compile SDK 36
- min SDK 24
- target SDK 36
- NDK `29.0.13113456`

### 5. Configure Build-Time Variables

Copy the example environment file and fill in your values:

```bash
cp env.json.example env.json
```

Pass it at run time with `--dart-define-from-file`:

```bash
fvm flutter run --dart-define-from-file=env.json
```

`env.json` is gitignored. `env.json.example` is the committed template showing every supported key.

Supported keys:

| Key | Required | Description |
|-----|----------|-------------|
| `GOOGLE_CLIENT_ID_ANDROID` | For Calendar | Android OAuth client ID |
| `GOOGLE_SERVER_CLIENT_ID` | For Calendar | Server OAuth client ID |
| `MODEL_CATALOG_URL` | No | Override the LLM model catalog URL |
| `STT_CATALOG_URL` | No | Override the STT model catalog URL |

When `MODEL_CATALOG_URL` or `STT_CATALOG_URL` are omitted the app falls back to built-in default URLs.

### 6. Launch the App

```bash
fvm flutter run --dart-define-from-file=env.json
```

---

## Configuration

### Model Catalogs

The app fetches model metadata at runtime from the MyBuddy-Admin-Panel API:

- LLM catalog: `GET /api/llm_models` on your deployed admin panel instance
- STT catalog: `GET /api/stt_models` on your deployed admin panel instance

Both URLs are compile-time configurable via `MODEL_CATALOG_URL` and `STT_CATALOG_URL` in `env.json`. When omitted, the app falls back to built-in default URLs. Point these to your admin panel deployment (e.g., `https://your-admin-panel.vercel.app/api/llm_models`).

Catalog entries provide:

- stable model IDs
- download URLs
- approximate display sizes
- minimum byte thresholds for validation
- runtime configuration for model loading

### Local Model Storage

- LLM models are stored inside the app documents directory
- STT models are stored separately with optional CoreML encoder folders on Apple platforms
- installation registries track downloaded models and metadata locally

### Overlay and Unity

Android overlay support depends on the local `flutter_overlay_window` package and the user granting overlay permission.

Unity avatar support depends on the exported `android/unityLibrary` module being present and aligned with the host app.

---

## Running the App

### Development Run

```bash
fvm flutter run -d android --dart-define-from-file=env.json
```

### Useful Variants

```bash
fvm flutter run --release
fvm flutter run -d chrome
fvm flutter run -d windows
```

Use non-Android targets for general UI work only. The full product experience, including embedded Unity avatar and overlay, is currently Android-focused.

### First-Run Workflow

1. Open Settings.
2. Download and select an LLM model.
3. Download and select a Whisper STT model.
4. Return to chat and start a conversation.
5. Grant overlay permission if you want the floating assistant experience.

---

## Building for Release

### Android APK

```bash
fvm flutter build apk --release --dart-define-from-file=env.json
```

### Android App Bundle

```bash
fvm flutter build appbundle --release --dart-define-from-file=env.json
```

### iOS Build

```bash
fvm flutter build ios --release --dart-define-from-file=env.json
```

iOS builds do not include the Android overlay or Unity Android library path.

### Android Native Build

If you need to assemble from Gradle directly:

```bash
cd android
./gradlew app:assembleRelease
```

On Windows:

```powershell
.\gradlew.bat app:assembleRelease
```

---

## How to Use the App

### Chat

- type a message and send it for LLM response generation
- hold the microphone control to record speech and transcribe it
- allow the assistant to trigger avatar animations when supported by the selected model

### Settings

- manage LLM downloads and active model selection
- manage STT downloads and optional CoreML assets
- adjust personalization and memory behavior
- configure notification behavior and overlay preferences

### Calendar

- sign in with Google
- browse events in the calendar view
- create events from the calendar UI or natural-language assistant requests

---

## Development Workflow

### Analyze

```bash
fvm flutter analyze
```

### Test

```bash
fvm flutter test
```

### Regenerate or Refresh Native Dependencies

```bash
fvm flutter clean
fvm flutter pub get
```

When the Unity export changes, sync the `android/unityLibrary` and `android/launcher` modules from the companion Unity repository export before rebuilding Android.

---

## Troubleshooting

### Models do not appear in Settings

- verify network access to the admin panel API endpoints
- confirm the admin panel is deployed and serving valid JSON catalogs
- restart the app after transient network failures

### Unity avatar does not respond on Android

- confirm `android/unityLibrary` is present and synced from the Unity export
- verify the Android build still includes `implementation(project(":unityLibrary"))`
- rebuild the Android app after updating the Unity export

### Overlay does not open

- verify overlay permission is granted on the device
- test on Android, not on desktop or web targets
- confirm the local `flutter_overlay_window` package builds correctly

### Calendar sign-in fails

- verify `--dart-define` values are present at run or build time
- confirm OAuth credentials are configured for the correct platform package or bundle ID

### Flutter commands use the wrong SDK

- run `fvm install` from the project root
- use `fvm flutter ...` instead of `flutter ...`
- if your editor is still using a global SDK, point it to `.fvm/flutter_sdk`

---

## Repository Layout

```text
android/      Android host, Unity library modules, Gradle config
assets/       Images and static assets
ios/          iOS runner
lib/          Flutter application source
linux/        Linux host
macos/        macOS host
packages/     Local Flutter packages
test/         Flutter tests
web/          Web host
windows/      Windows host
```

---

## License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.
