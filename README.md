<p align="center">
  <img src="ShadowPilot/shadow_pilot_logo_no_bg.png" width="120" alt="ShadowPilot Logo" />
</p>

<h1 align="center">ShadowPilot — macOS</h1>

<p align="center">
  <b>Real-time AI interview copilot that lives in a transparent overlay on your screen.</b><br/>
  Listens to interview questions, captures your screen, and generates tailored answers — all invisible to the interviewer.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-black?style=flat-square&logo=apple&logoColor=white" />
  <img src="https://img.shields.io/badge/swift-5.9-F05138?style=flat-square&logo=swift&logoColor=white" />
  <img src="https://img.shields.io/badge/xcode-15%2B-147EFB?style=flat-square&logo=xcode&logoColor=white" />
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" />
</p>

---

## ✨ Features

| Feature | Description |
|---|---|
| 🎙️ **Live Transcription** | Captures system audio (meeting apps) and transcribes in real-time using Apple's `Speech` framework |
| 🧠 **Smart Model Routing** | Auto-detects question type — Q&A → **Groq** (fastest), Code Review/Coding → **Claude Sonnet 4.5**, System Design → **GPT-4o** — with manual override pills |
| 🏁 **Hedged Racing** | Q&A questions fire the two fastest providers in parallel — first token wins, loser cancelled |
| 📸 **Screenshot Analysis** | One-click screen capture + Claude Sonnet vision — approach first, then fully-commented code |
| 🪟 **Invisible Overlay** | Glassmorphic floating pill that stays on top of all windows — undetectable in screen shares |
| ⌨️ **Global Hotkeys** | Control everything without switching apps — no suspicious alt-tabs |
| 💬 **Conversation Memory** | Always-on rolling history — follow-ups inherit context AND mode ("now add multi-region" answers only the delta) |
| 👁️ **Whisper Mode** | Answer reveals gradually, mimicking natural reading speed on camera |
| ⚡ **Hands-free Mode** | Silence-triggered answers with continuous listening — follow-ups spoken mid-answer are never missed. **Headphones required** (speaker audio can self-trigger it) |
| 🩺 **Provider Health Check** | Every provider tested at launch with live latency — dead providers auto-excluded from routing |
| 🗂️ **Session History** | Every Q&A logged to local SQLite with optional Neon cloud backup — searchable, exportable as Markdown |
| 🎯 **Session Context** | Paste the job description + your resume so every answer is role-specific |
| 🗣️ **Filler Phrases** | Shows natural filler text instantly while AI thinks — no awkward pauses |

---

## 🛠 Prerequisites

- **macOS 13.0+** (Ventura or later)
- **Xcode 15+** with Swift 5.9
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** — `brew install xcodegen`
- At least **one** API key (Bedrock, OpenRouter, or OpenAI)

---

## ⚡ One-Line Install (Recommended)

Paste this in Terminal and you're done — it handles everything automatically:

```bash
curl -fsSL https://raw.githubusercontent.com/shivanshu814/ShadowPilot-MacOS/main/install.sh | bash
```

This will:
1. ✅ Check macOS version & install Xcode CLI tools if missing
2. ✅ Install Homebrew + XcodeGen if missing
3. ✅ Clone the repo to `~/.shadowpilot`
4. ✅ Prompt you for an API key and save it to `~/.shadowpilot.env`
5. ✅ Build the app and install it to `/Applications/ShadowPilot.app`
6. ✅ Offer to launch immediately

> **Uninstall anytime:** `bash ~/.shadowpilot/uninstall.sh`

---

## 🚀 Manual Setup (Step by Step)

If you prefer doing it yourself:

### 1. Clone the repo

```bash
git clone https://github.com/shivanshu814/ShadowPilot-MacOS.git
cd ShadowPilot-MacOS
```

### 2. Set up environment variables

```bash
cp .env.example .env
```

Open `.env` and fill in at least one API key:

```env
# Groq (fastest — primary for Q&A)
GROQ_API_KEY=gsk_...

# OpenRouter (Claude Sonnet 4.5 — review/design/coding)
OPENROUTER_API_KEY=sk-or-v1-...

# OpenAI (GPT-4o — system design)
OPENAI_API_KEY=sk-...

# Optional fallbacks
BEDROCK_API_KEY=...
BEDROCK_REGION=us-east-1
ACCOUNT_ID=...      # Cloudflare Workers AI
API_TOKEN=...       # Cloudflare Workers AI

# Optional cloud backup of session history
NEON_DATABASE_URL=postgresql://...
```

> **Tip:** The app searches for `.env` in multiple locations:  
> `~/.shadowpilot.env` → `~/.env` → project root → app bundle → DerivedData

### 3. Generate the Xcode project

```bash
xcodegen generate
```

### 4. Build & Run

**Option A — Xcode:**
```
Open ShadowPilot.xcodeproj → Select scheme "ShadowPilot" → ⌘R
```

**Option B — Terminal:**
```bash
xcodebuild -scheme ShadowPilot -configuration Debug -derivedDataPath build build
```

Then launch the app:
```bash
open build/Build/Products/Debug/ShadowPilot.app
```

### 5. (Optional) Install to /Applications

```bash
cp -R build/Build/Products/Debug/ShadowPilot.app /Applications/
```

Now you can launch ShadowPilot from **Spotlight** (`⌘ Space` → type "ShadowPilot") or from the **Applications** folder.

---

## 📦 Direct Install (Pre-built .app)

If you don't want to build from source, download the latest `.app` from [Releases](https://github.com/shivanshu814/ShadowPilot-MacOS/releases):

1. Download `ShadowPilot.app.zip` from the latest release
2. Unzip and drag `ShadowPilot.app` to `/Applications`
3. Create your env file:
   ```bash
   cp ~/.shadowpilot.env.example ~/.shadowpilot.env
   # Edit ~/.shadowpilot.env and add your API key
   ```
4. Launch from Applications or Spotlight
5. On first launch, **right-click → Open** to bypass Gatekeeper (unsigned app)

---

## 🔐 First Launch — Grant Permissions

On first launch, macOS will ask for:
- 🎤 **Microphone** — to hear interview questions
- 🗣️ **Speech Recognition** — to transcribe audio
- 🖥️ **Screen Recording** — to capture system audio from meeting apps

> **Note:** If hotkeys don't work, go to **System Settings → Privacy & Security → Accessibility** and add ShadowPilot.

---

## ⌨️ Keyboard Shortcuts

All hotkeys work **globally** — no need to focus the app window.

| Shortcut | Action |
|---|---|
| `⌘⇧L` | Start / Stop listening |
| `⌘⇧A` | Get AI answer |
| `⌘⇧D` | Capture screenshot + analyze |
| `⌘⇧X` | Clear everything |
| `⌘⇧W` | Toggle typing mode |

---

## 🏗 Project Structure

```
ShadowPilot-macOS/
├── install.sh                    # One-click installer (curl | bash)
├── .env.example                  # Environment template
├── project.yml                   # XcodeGen project spec
├── ShadowPilot/
│   ├── ShadowPilotApp.swift      # App entry point
│   ├── AppDelegate.swift         # Menu bar + window management
│   ├── OverlayWindowController.swift  # Floating transparent overlay
│   ├── Info.plist                # Permissions declarations
│   ├── ShadowPilot.entitlements  # macOS entitlements
│   ├── Services/
│   │   ├── EnvConfig.swift       # .env file parser
│   │   ├── AppViewModel.swift    # Core app logic & state
│   │   ├── BedrockService.swift  # AWS Bedrock API (streaming)
│   │   ├── GPTService.swift      # OpenAI / OpenRouter API (streaming)
│   │   ├── HotkeyManager.swift   # Global keyboard shortcuts
│   │   ├── ScreenshotCapture.swift   # ScreenCaptureKit integration
│   │   ├── SpeechRecognizer.swift    # Apple Speech framework
│   │   ├── SystemAudioCapture.swift  # System audio capture
│   │   ├── SilenceDetector.swift     # Silence detection for auto-mode
│   │   └── ConversationTurn.swift    # Chat history model
│   └── Views/
│       ├── ContentView.swift     # Main overlay UI (Spotlight-style bar)
│       ├── SetupView.swift       # Session setup (JD + Resume input)
│       ├── AnswerView.swift      # AI answer display
│       └── MarkdownView.swift    # Markdown rendering
```

---

## 🔑 Model Routing

Every question is routed to the **fastest model that is still correct for that question type**:

| Question type | Primary model | Fallbacks |
|---|---|---|
| Interview Q&A | Groq Llama 3.3 70B (raced vs Cloudflare) | Bedrock → OpenAI → OpenRouter |
| Code Review / PR | OpenRouter Claude Sonnet 4.5 | OpenAI GPT-4o → others |
| System Design | OpenAI GPT-4o | OpenRouter Sonnet → others |
| Coding (screenshot) | OpenRouter Claude Sonnet 4.5 (vision) | OpenAI GPT-4o |

You only need **one** working key — the router skips unconfigured/unhealthy providers. **Groq is strongly recommended** for Q&A speed (~300ms first token). Model IDs are overridable via `.env` (see `.env.example`).

---

## 🔒 Privacy & Security

- All API keys are stored **locally** in `.env` (gitignored by default)
- No data is sent to any server other than the AI provider you configure
- Audio is processed on-device via Apple's Speech framework
- Screenshots are captured locally via ScreenCaptureKit
- The app never stores conversation data to disk

---

## 📋 macOS Permissions

| Permission | Why |
|---|---|
| Microphone | Capture audio to hear interview questions |
| Speech Recognition | Transcribe speech to text on-device |
| Screen Recording | Capture system audio from meeting apps (Zoom, Meet, etc.) |
| Accessibility (optional) | Required for global hotkeys to work in some configurations |

---

## 🤝 Contributing

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/awesome-thing`)
3. Commit your changes (`git commit -m 'Add awesome thing'`)
4. Push to the branch (`git push origin feature/awesome-thing`)
5. Open a Pull Request

---

## 📜 License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE) file for details.

---

<p align="center">
  <b>Built with ❤️ for interview warriors everywhere.</b><br/>
  <sub>⭐ Star this repo if ShadowPilot helped you land the job!</sub>
</p>
