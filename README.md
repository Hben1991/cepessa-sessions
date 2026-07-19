<div align="center">

# **Cepessa Sessions**

### A 2nd brain you trust more than your 1st

Cepessa Sessions captures your screen and conversations, transcribes in real time, generates summaries and action items, and gives you an AI chat that remembers everything you've seen and heard. Works on desktop, phone, and wearables. Fully open source.

Trusted by 300,000+ professionals.


[![GitHub Repo stars](https://img.shields.io/github/stars/Hben1991/cepessa-sessions?style=for-the-badge)](https://github.com/Hben1991/cepessa-sessions)&ensp;
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=for-the-badge)](https://opensource.org/licenses/MIT)

[Repository](https://github.com/Hben1991/cepessa-sessions) · [Desktop](desktop/) · [App](app/) · [Backend](backend/)

</div>

## Quick Start

<p align="center">
  <a href="https://apps.apple.com/us/app/friend-ai-wearable/id6502156163"><img src="docs/assets/readme/download-appstore-badge.png" alt="Download on the App Store" height="50"></a>
  <a href="https://play.google.com/store/apps/details?id=com.friend.ios"><img src="docs/assets/readme/download-gplay-badge.png" alt="Get it on Google Play" height="50"></a>
</p>

```bash
git clone https://github.com/Hben1991/cepessa-sessions.git && cd cepessa-sessions/desktop && ./run.sh --yolo
```

Builds the macOS app, connects to the cloud backend, and launches. No env files, no credentials, no local backend.

> **Requirements:** macOS 14+, [Xcode](https://developer.apple.com/xcode/) (includes Swift & code signing), [Node.js](https://nodejs.org/)

<details>
  <summary>Full Installation</summary>
  
For local development with the full backend stack:

1. Install prerequisites

```bash
xcode-select --install
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

2. Clone and configure

```bash
git clone https://github.com/Hben1991/cepessa-sessions.git
cd cepessa-sessions/desktop
cp Backend-Rust/.env.example Backend-Rust/.env
```

3. Build and run

```bash
./run.sh
```

See [desktop/README.md](desktop/README.md) for environment variables and credential setup.


### Mobile App

```bash
cd app && bash setup.sh ios    # or: bash setup.sh android
```

</details>

<details>
  <summary>How it works</summary>


```
┌─────────────────────────────────────────────────────────┐
│                      Your Devices                       │
│                                                         │
│  ┌──────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │ Cepessa  │  │ macOS App    │  │ Mobile App        │  │
│  │ Device   │  │ (Swift/Rust) │  │ (Flutter)         │  │
│  └────┬─────┘  └──────┬───────┘  └────────┬──────────┘  │
│       │    BLE         │   HTTPS/WS        │             │
└───────┼────────────────┼───────────────────┼─────────────┘
        │                │                   │
        ▼                ▼                   ▼
┌─────────────────────────────────────────────────────────┐
│                 Cepessa Backend (Python)                 │
│                                                         │
│  ┌─────────┐  ┌──────────┐  ┌─────────┐  ┌──────────┐  │
│  │ Listen  │  │ Pusher   │  │ VAD     │  │ Diarizer │  │
│  │ (REST)  │  │ (WS)     │  │ (GPU)   │  │ (GPU)    │  │
│  └─────────┘  └──────────┘  └─────────┘  └──────────┘  │
│                                                         │
│  ┌─────────┐  ┌──────────┐  ┌─────────┐  ┌──────────┐  │
│  │ Deepgram│  │ Firestore│  │ Redis   │  │ LLMs     │  │
│  │ (STT)   │  │ (DB)     │  │ (Cache) │  │ (AI)     │  │
│  └─────────┘  └──────────┘  └─────────┘  └──────────┘  │
└─────────────────────────────────────────────────────────┘
```

| Component | Path | Stack |
|-----------|------|-------|
| **macOS app** | [`desktop/`](desktop/) | Swift, SwiftUI, Rust backend |
| Mobile app | [`app/`](app/) | Flutter (iOS & Android) |
| Backend API | [`backend/`](backend/) | Python, FastAPI, Firebase |
| Firmware | Embedded firmware directories | nRF, Zephyr, C |
| Smart Glass | Embedded glass firmware directories | ESP32-S3, C |
| SDKs | [`sdks/`](sdks/) | React Native, Swift, Python |
| AI Personas | [`web/personas-open-source/`](web/personas-open-source/) | Next.js |

</details>

## Documentation

### Getting Started
- [Introduction](docs/)
- [Quick Start Guide](desktop/README.md)
- [macOS App Development](desktop/README.md)
- [Mobile App Setup](app/README.md)
- [Backend Setup](backend/README.md)
- [Contributing](CONTRIBUTING.md)

### Building Apps
- [App Development Guide](docs/doc/developer/)
- [Example Apps](docs/doc/developer/apps/examples/)
- [Audio Streaming Apps](docs/doc/developer/apps/)
- [Custom Chat Tools](docs/doc/developer/apps/)
- [Submit to App Store](docs/doc/developer/apps/)

### API & SDKs
- API reference lives alongside the backend and SDK source in this repository.
- [Python SDK](sdks/python/)
- [Swift SDK](sdks/swift/)
- [React Native SDK](sdks/react-native/)
- [MCP Server](mcp/) — Model Context Protocol integration

### Architecture
- [Backend Deep Dive](docs/doc/developer/backend/)
- [Transcription Pipeline](docs/doc/developer/backend/)
- [Chat System](docs/doc/developer/backend/)
- [Audio Streaming Pipeline](docs/doc/developer/backend/listen_pusher_pipeline.mdx)
- [BLE Protocol](docs/doc/developer/Protocol.mdx)

## Hardware
![Cepessa Device](https://github.com/user-attachments/assets/7a658366-9e02-4057-bde5-a510e1f0217a)

Open-source AI wearables that pair with the mobile app for 24h+ continuous capture.

<p align="center">
  <img src="https://github.com/user-attachments/assets/834d3fdb-31b5-4f22-ae35-da3d2b9a8f59" alt="Cepessa wearable" width="49%" />
  <img src="https://github.com/user-attachments/assets/fdad4226-e5ce-4c55-b547-9101edfa3203" alt="Cepessa smart glasses" width="49%" />
</p>

- [Open Source Hardware Designs](docs/doc/hardware/)
- [Buying Guide](docs/doc/assembly/)
- [Build the Device](docs/doc/assembly/)
- [Flash Firmware](docs/doc/get_started/)
- [Integrate Your Wearable](docs/doc/integrations/)
- [Hardware Specs](docs/doc/hardware/)

## License

MIT — see [LICENSE](LICENSE)
