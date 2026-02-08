# Read the Room

An anonymous social Q&A platform where anyone can ask questions and see how the world answers. Built with Flutter, powered by Supabase.

## Features

- **Question types** — Multiple choice, approval rating, and free text
- **Location-based results** — See how answers break down by country on interactive choropleth maps
- **Question of the Day** — Daily featured question with answer streaks
- **Rooms** — Private spaces for groups to ask and answer questions together
- **Categories** — Filter by topic (pop culture, philosophy, politics, and more)
- **Suggestions** — Community-driven question ideas with voting
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

```bash
cd readtheroom
flutter pub get
flutter analyze
flutter run
```

Requires Flutter SDK 3.x. You'll need your own Supabase project, Firebase project, and PostHog instance to run a full local build.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to report bugs, request features, and more.

## Security

To report a vulnerability, see [SECURITY.md](SECURITY.md).

## License

Source code is licensed under the [GNU Affero General Public License v3.0](LICENSE).

Trademarked assets (name, logos, Curio mascot) are not covered by the AGPLv3 license. See [TRADEMARK.md](TRADEMARK.md) for details.

Third-party attributions are listed in [NOTICE](NOTICE).
