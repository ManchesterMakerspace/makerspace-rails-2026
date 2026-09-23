# Keyfobbit

A deliberately small Android NFC utility for authorized board members and administrators. It signs into the existing Rails API with a password or Google/Firebase, supports the portal's TOTP challenge, enables Android NFC reader mode, accepts MIFARE Classic tags, and looks up the scanned UID. A card result can open its associated member record, while an unknown UID can be recorded in the rejections collection.

## Build

Requirements: JDK 17 or newer and Android SDK Platform 35.

```sh
gradle wrapper
./gradlew assembleDebug
```

The APK is written to `app/build/outputs/apk/debug/app-debug.apk`. Android Studio can also open this directory directly.

The Gradle wrapper JAR is committed as `gradle-wrapper.jar.base64.txt` so the
project can pass through pull-request systems that reject binary attachments.
Both `gradlew` and `gradlew.bat` automatically reconstruct the ignored JAR on
their first invocation; do not commit the generated `.jar`.

## Use

1. Install the APK on an NFC-capable Android device running Android 6.0 or newer.
2. Enter the HTTPS root URL for the member portal (without `/api`) and use either board/admin credentials or **Sign in with Google / Firebase**. Native federated login requires `FIREBASE_API_KEY`, `FIREBASE_PROJECT_ID`, `FIREBASE_APP_ID`, and `FIREBASE_WEB_CLIENT_ID` on the server.
3. Complete TOTP when requested.
4. Hold a MIFARE Classic card to the device. Keyfobbit converts Android's raw UID bytes to zero-padded uppercase hexadecimal and calls `GET /api/admin/cards/by_uid?uid=...`. If it is unknown, the confirmation button records it through `POST /api/admin/rejections`.

The application intentionally rejects cleartext HTTP, does not persist credentials or session cookies, and clears its in-memory session when the process exits. Some Android hardware cannot read MIFARE Classic tags because the NFC chipset lacks Classic support.
