# Read the Room

An anonymous social Q&A platform where anyone can ask questions and see how the world answers. Built with Flutter, powered by Supabase.

## Features

- **Question types** — Multiple choice, approval rating, and free text
- **Location-based results** — See how answers break down by country on interactive choropleth maps
- **Question of the Day** — Daily featured question with answer streaks
- **Friends** — Add friends by QR code or handle, chat, and see how your circle answered
- **Categories** — Filter by topic (pop culture, philosophy, politics, and more)
- **Comments** — Discuss results with lizzy votes (🦎 upvotes)
- **Passkey authentication** — Passwordless sign-in via WebAuthn/FIDO2
- **Push notifications** — Question activity alerts, QotD reminders, streak nudges
- **Dark/light theme** — System-aware with manual override
- **iOS widgets** — QotD and streak widgets for the home/lock screen

## Tech Stack

| Layer | Technology |
|-------|-----------|
| App | Flutter (Dart) |
| State management | Provider |
| Backend | Supabase (PostgreSQL, Auth, Edge Functions, Realtime) |
| Push notifications | Firebase Cloud Messaging |
| Maps | flutter_map + Natural Earth GeoJSON |
| Analytics | PostHog |
| Auth | WebAuthn/FIDO2 passkeys with device binding |

## Project Structure

```
readtheroom/
├── lib/
│   ├── main.dart                  # Entry point, FCM setup, deep link handling
│   └── src/
│       ├── models/                # Data models
│       ├── screens/               # Full-screen pages
│       ├── services/              # Business logic and API layer
│       ├── utils/                 # Helpers, constants, GeoJSON parser
│       └── widgets/               # Reusable UI components
├── assets/
│   ├── images/                    # Logos, mascot variants
│   └── data/                      # GeoJSON, city data
├── ios/                           # iOS platform code + widgets
├── android/                       # Android platform code
├── macos/                         # macOS platform code
└── pubspec.yaml                   # Dependencies
```

## Getting Started

Requires Flutter SDK 3.x. The app has **no built-in backend**: you need your own
Supabase project and Firebase project (PostHog is optional). Nothing in this
repository points at the production service.

1. **Build-time config.** Copy `.env.example` to `.env` and fill in your
   Supabase URL and anon (publishable) key. The app refuses to start without
   them. Never use a service-role or secret key in a client build.
2. **Firebase.** Generate your own configs with the FlutterFire CLI
   (`flutterfire configure` inside `readtheroom/`). This creates
   `lib/firebase_options.dart`, `android/app/google-services.json` and
   `ios/Runner/GoogleService-Info.plist`, all git-ignored.
3. **iOS native config (optional).** Copy
   `readtheroom/ios/Flutter/Secrets.xcconfig.example` to `Secrets.xcconfig`
   for the widgets and background fetch.
4. **Android release signing (optional).** Copy
   `readtheroom/android/key.properties.example` to `key.properties`.

```bash
cd readtheroom
flutter pub get
flutter analyze
flutter run --dart-define-from-file=../.env
```

iOS signing, the app group and associated domains are tied to the maintainer's
Apple team; change the bundle identifier and team in Xcode to run on a device.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to report bugs, request features, and more.

## Security

To report a vulnerability, see [SECURITY.md](SECURITY.md).

## License

Source code is licensed under the [GNU Affero General Public License v3.0](LICENSE).

Trademarked assets (name, logos, Curio mascot) are not covered by the AGPLv3 license. See [TRADEMARK.md](TRADEMARK.md) for details.

Third-party attributions are listed in [NOTICE](NOTICE).
