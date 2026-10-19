# PictoIQ

PictoIQ is a privacy-first photo library prototype. It is an ASP.NET Core 9 web app with a local-only browser experience: images are selected explicitly, fingerprints are calculated in the browser, and the catalogue is stored in IndexedDB. The server exposes only the static app and a health endpoint; photo files and fingerprints are not sent to it.

## Run locally

From the `PictoIQ` directory:

```powershell
dotnet run
```

Open the local URL printed by ASP.NET Core. Use **Choose photos** to select images, then review the library and exact-match groups. The app works best in a modern browser with IndexedDB and Web Crypto support.

Use **Remove from library** on a photo card to remove its saved index entry and current preview from PictoIQ. This does not delete or modify the original photo file.

## Current scope and limitations

- Supports selected image files only. Videos, incremental mobile-media enumeration, SQLite, cloud accounts, and machine-learning analysis are not implemented.
- Exact matches are determined by SHA-256; files larger than 100 MB are skipped to bound browser memory use.
- The local browser index stores image names, sizes, dates, and hashes—not image contents. Browser file access expires with the page, so reload the original files to preview them again.
- The web app cannot request operating-system photo deletion approval and never deletes originals. Safe cleanup requires the native mobile media APIs, an explicit confirmation flow, and handling platform approval/partial failures.
- The target architecture in the supplied brief is a Flutter Android/iOS app with a .NET 10 backend added later. This prototype still targets .NET 9; installing .NET 10 does not migrate it or turn it into the native app.

## Android development environment

The following tools have been installed on this Windows machine:

| Tool | Version / location |
| --- | --- |
| Flutter | 3.47.7, `C:\Users\rkumar775\develop\flutter` |
| Dart | 3.13.5, bundled with Flutter |
| Java | Microsoft OpenJDK 21, `C:\Program Files\Microsoft\jdk-21.0.12.101-hotspot` |
| Android SDK | `C:\Users\rkumar775\AppData\Local\Android\Sdk` |
| Android platform | API 36 |
| Android build tools | 36.0.0 |
| Android platform tools | Includes `adb` |
| .NET SDK | 10.0.402, alongside the existing SDKs |
| Editor | VS Code with the Flutter and Dart extensions |

Flutter's `bin` and the Android `platform-tools` directory were added to the user PATH. `ANDROID_HOME` was set for the user, and the Java installer configured machine-level `JAVA_HOME`. Flutter was explicitly configured to use these SDK and JDK locations. Restart VS Code and open a new terminal to pick up the environment changes.

Verify the setup:

```powershell
flutter --version
dart --version
java -version
adb version
dotnet --list-sdks
flutter doctor -v
flutter devices
```

The existing web project was successfully rebuilt using .NET SDK 10 after restoring its .NET 9 targeting packs. A separate Flutter Android sample was generated, but its first APK build was stopped at the user's request while bootstrapping dependencies. An Android APK build and real-device run have not yet been verified.

### Optional Android Studio and emulator

Android Studio's automatic download was stopped after it did not progress. Android builds can use VS Code and the command-line SDK without Android Studio. For its SDK Manager and visual emulator management, install it manually:

```powershell
winget install --id Google.AndroidStudio --exact --source winget
```

Alternatively, download the installer from [Android Studio](https://developer.android.com/studio). Launch it, complete its setup wizard, and point its SDK location at `C:\Users\rkumar775\AppData\Local\Android\Sdk`.

The SDK already contains API 36, build-tools 36.0.0, command-line tools, and platform-tools. Reuse those installations rather than downloading a second SDK.

In **More Actions > SDK Manager**, select API 36 and the SDK tools required by the project. In **Device Manager**, create an Android virtual device and download a matching system image. Enable hardware virtualization in firmware if the emulator requires it. A physical Android phone is an alternative: enable Developer options and USB debugging, connect it, accept the phone's authorization prompt, and confirm it appears in `flutter devices`. Some phones need their manufacturer's Windows USB driver.

### Additional native build dependencies

The first Flutter build downloads Gradle and Maven dependencies and can install the NDK required by its project. Flutter 3.47.7 defaults to NDK `28.2.13676358`. Plugins can require other versions or CMake; install the exact versions requested by the project rather than arbitrary latest versions.

The currently installed Android command-line tools include the new `android.exe` CLI. Its package identifiers use `/`, rather than the older `sdkmanager` semicolon identifiers. For example:

```powershell
$android = "$env:ANDROID_HOME\cmdline-tools\latest\bin\android.exe"
& $android --sdk "$env:ANDROID_HOME" sdk install "ndk/28.2.13676358"
& $android --sdk "$env:ANDROID_HOME" sdk install "cmake/3.22.1"
```

Use `& $android sdk install --help` and `& $android sdk list --all` to inspect supported commands and packages. Review any new licence prompts. Do not assume an installation succeeded solely from an exit code; confirm the installed files and run `flutter doctor -v`.

### Building the future mobile project

The current repository contains the web prototype, not a Flutter mobile application. After the mobile project is implemented, run these commands from the directory containing its `pubspec.yaml`:

```powershell
flutter pub get
flutter analyze
flutter test
flutter run -d <device-id>
flutter build apk --debug
```

Store release builds additionally require application IDs, release signing, and secure handling of the signing key. Prefer a short, local, non-OneDrive path for Android development if synchronized folders, long paths, or file locks cause Gradle problems.

### Later cloud and other platform prerequisites

- SQLite on-device support is supplied through the chosen Flutter package; a separate SQLite server is not required.
- PostgreSQL is needed when implementing the cloud backend, not for the offline Android MVP. Install [PostgreSQL](https://www.postgresql.org/download/windows/) or use a development container when that phase begins.
- Docker Desktop is optional for containerized PostgreSQL and backend services. Check its licensing and WSL 2/virtualization requirements before installing it.
- Windows desktop Flutter builds need Visual Studio with **Desktop development with C++**. That workload is not required for Android builds and was not installed.
- iOS builds require a Mac with Xcode and the current Flutter iOS prerequisites. A signed device/store build also requires Apple signing setup; Windows cannot build the iOS app locally.

Official instructions: [Flutter installation](https://docs.flutter.dev/install/manual), [Flutter Android setup](https://docs.flutter.dev/platform-integration/android/setup).
