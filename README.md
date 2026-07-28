# WA Business for macOS

A real-time AI copilot that runs in a transparent overlay on top of every other
window. It listens to the conversation, reads your screen when you ask it to,
and can answer questions about a real codebase using actual file paths and line
numbers.

Platform: macOS 13 or later. Swift 5.9. Xcode 15 or later.


## What it does

**Live transcription.** Captures system audio from meeting apps and transcribes
it on-device with Apple's Speech framework.

**Smart routing.** Every question is classified into a mode, and each mode has
its own ordered chain of AI providers. Q&A goes to the fastest models, anything
touching code goes to the strongest.

**Hedged racing.** For Q&A the two fastest providers are called in parallel and
the first one to produce a token wins. The loser is cancelled mid-stream.

**Repo mode.** Point it at a codebase and answers come back citing real files
and real line ranges, with the exact diff to apply. See "Repo mode" below.

**Cloud review.** Hands the whole repository to a Cursor cloud agent, which
reads all of it and writes a findings report. See "Cloud review" below.

**Screenshot analysis.** One keystroke captures the screen and sends it to a
vision model, which returns an approach followed by fully commented code.

**Conversation memory.** A rolling history means follow-ups inherit both the
context and the mode. Asking "now add multi-region" answers only the delta
instead of regenerating the whole design.

**Whisper mode.** Reveals the answer gradually so reading it aloud on camera
looks natural.

**Hands-free mode.** Fires an answer when the speaker pauses, and keeps
listening throughout. Headphones are required, otherwise speaker audio
retriggers it.

**Provider health checks.** Every provider is tested at launch with live
latency. Dead ones are dropped from routing automatically.

**Session history.** Every exchange is written to a local SQLite database, with
optional backup to Neon Postgres. Searchable, and exportable as Markdown.

**Role context.** Paste the job description and your resume so answers are
specific to the role.

**Speaking style.** Pick an accent preset or record a voice sample, and answers
get written in your phrasing so they sound like you when read aloud.


## Requirements

- macOS 13.0 or later
- Xcode 15 or later, with Swift 5.9
- XcodeGen: `brew install xcodegen`
- At least one AI provider API key


## Install

### One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/shivanshu814/ShadowPilot-MacOS/main/install.sh | bash
```

It checks the macOS version, installs the Xcode command line tools, Homebrew
and XcodeGen if any are missing, clones the repo to `~/.wabusiness`, builds a
Release binary, and installs it to `/Applications`. If `/Applications` is not
writable it falls back to `~/Applications` instead of failing.

Keys are picked up automatically. The installer looks for an existing env file
in the directory you ran it from, then `~/.shadowpilot.env`, then `~/.env`, and
copies every filled key into `~/.wabusiness.env`. Keys already set there are
never overwritten, so re-running it is safe. Only if nothing is found does it
ask for a single key, and it works out the provider from the key's own prefix
(`gsk_` for Groq, `sk-or-v1-` for OpenRouter, `sk-` for OpenAI).

Uninstall:

```bash
bash ~/.wabusiness/uninstall.sh            # removes the app, keeps your keys
bash ~/.wabusiness/uninstall.sh --purge    # also deletes ~/.wabusiness.env
```

### Build from source

```bash
git clone https://github.com/shivanshu814/ShadowPilot-MacOS.git
cd ShadowPilot-MacOS
cp .env.example ~/.wabusiness.env
```

Open `~/.wabusiness.env` and fill in at least one key. Then:

```bash
xcodegen generate
xcodebuild -scheme WABusiness -configuration Debug -derivedDataPath build build
open "build/Build/Products/Debug/WA Business.app"
```

To install it permanently:

```bash
cp -R "build/Build/Products/Debug/WA Business.app" /Applications/
```

You can also open `WABusiness.xcodeproj` in Xcode, select the WABusiness
scheme, and press Cmd+R.

### Pre-built app

Download the latest `WA Business.app.zip` from the Releases page, unzip it,
drag the app to `/Applications`, and create `~/.wabusiness.env` with your key.
The app is unsigned, so on first launch use right-click then Open to get past
Gatekeeper.


## Configuration

Keys are read from the first of these that has a value:

1. Process environment (useful when running from Xcode)
2. `~/.wabusiness.env`
3. `~/.env`
4. `.env` next to the app bundle, or in any parent directory up to eight levels

`~/.wabusiness.env` is the most reliable location, because it works no matter
where the app is installed. See `.env.example` for the full list of keys and
what each provider is used for.


## Routing

Each mode has an ordered chain and falls back left to right. A key you leave
blank drops that provider from every chain. One working key is enough to run.

| Mode | Chain | Token budget |
|---|---|---|
| Q&A and Auto | Groq, Cloudflare, Bedrock, OpenAI, OpenRouter GPT-4o | 512 |
| Code | OpenRouter Sonnet 4.5, OpenAI, OpenRouter GPT-4o, Groq, Bedrock | 8192 |
| Review | OpenRouter Sonnet 4.5, OpenAI, OpenRouter GPT-4o, Groq, Bedrock | 4096 |
| Design | OpenRouter Sonnet 4.5, OpenAI, Groq, Bedrock, Cloudflare | 8192 |
| Local | OpenRouter Sonnet 4.5, OpenAI, OpenRouter GPT-4o, Bedrock | 8192 |
| Screenshot | OpenRouter Sonnet 4.5, OpenAI, OpenRouter GPT-4o (vision only) | 8192 |
| Cloud | Cursor agent, no chain and no fallback | not applicable |

How fallback behaves:

1. Providers with no key, or muted in Setup, are removed before the chain runs.
2. Q&A and Auto race the top two survivors in parallel. First token wins, the
   loser is cancelled. If both fail, the rest of the chain is tried in order.
3. Every other mode is sequential: on any error, move to the next provider. An
   error only reaches the screen when all of them have failed.
4. If a reply is cut off at the token budget, it auto-continues on the same
   provider for up to three rounds, so the full answer always arrives.
5. Failing providers are flagged in Setup, where you can mute one so it stops
   being tried at all.

Groq is strongly recommended for Q&A speed. OpenRouter is the key that buys you
Claude Sonnet for everything code-related. Model IDs are overridable in the env
file if a model is ever renamed or retired.


## Repo mode

Load a codebase from the overlay bar, mid-conversation. Nothing is configured
in Setup or in the env file.

```
/repo ~/code/my-service          index a folder already on this Mac
/repo github.com/owner/name      shallow-clone it first, then index
```

A bare path or URL works too, without the `/repo` prefix. Cloning a private
repo needs `GITHUB_TOKEN` in the env file; the token is stripped from the git
remote after cloning and redacted from any error message.

Both sources end up identical. A cloned repo is written to disk and then
indexed exactly like a folder you already had, so where the code came from
changes nothing about how questions are answered.

Indexing is local: a BM25 index over overlapping line windows, with camelCase
and snake_case identifiers split so a question about "validate token" matches
`validateAccessToken`. Only the handful of matched snippets is ever sent to a
model. A medium repo indexes in well under a second and each query resolves in
a few milliseconds.

With a repo loaded, select the Local pill and answers arrive in this shape:

```
Open:         which files to pull up right now, full paths
What it does: what that code currently does, citing path:Lx-Ly
Answer:       the direct answer, or the defects, most severe first
Change:       the exact edit as a diff
Why:          why this fix, and what breaks without it
What to say:  a few spoken lines to use while making the edit
```

Line numbers are real. The model is given the true numbers alongside the source
and is told never to cite a line it cannot see.

Cmd+Shift+B sweeps the whole repo for defects in batches, streaming findings as
they arrive, each with a file, a line range, a severity and a suggested diff.


## Cloud review

The Cloud pill hands the repository to a Cursor cloud agent, which reads the
entire codebase and writes a report covering architecture, defects with file
and line references, weak spots, and talking points. The agent is instructed
not to edit files, not to commit, and not to open a pull request. It reports
only.

This needs `CURSOR_API_KEY` in the env file, and the repo has to be reachable
from your Cursor account. The agent runs on Cursor's own default model.

Two things to know. It takes minutes, not seconds, and it cannot stream, so run
it before an interview rather than during one. And it has no fallback: either
the Cursor key works or the review does not run.

Once a review finishes, its findings are kept and passed as background context
into every later Local answer, so the fast local path knows what the deep pass
already established. Findings can be cleared from Setup.

Selecting the Cloud pill starts a full review immediately. With Cloud selected,
anything you type becomes the review's focus, for example "focus on the auth
flow". Hands-free mode never triggers a cloud review, so a pause in
conversation cannot start a job that costs minutes.


## Keyboard shortcuts

All shortcuts are global. The app does not need to be focused.

| Shortcut | Action |
|---|---|
| Cmd+Shift+L | Start or stop listening |
| Cmd+Shift+A | Get an answer |
| Cmd+Shift+D | Capture the screen and analyze it |
| Cmd+Shift+B | Scan the loaded repo for bugs |
| Cmd+Shift+X | Clear everything |
| Cmd+Shift+W | Toggle typing mode |


## Permissions

macOS will ask for these on first launch.

| Permission | Why it is needed |
|---|---|
| Microphone | To hear the conversation |
| Speech Recognition | To transcribe audio on-device |
| Screen Recording | To capture system audio from meeting apps, and for screenshots |
| Accessibility | Needed for global hotkeys in some configurations |

If hotkeys do not respond, open System Settings, then Privacy and Security,
then Accessibility, and add WA Business.


## Privacy

- API keys are stored locally in the env file, which is gitignored.
- Nothing is sent anywhere except the AI providers you configure, plus Cursor
  if you use Cloud review, plus Neon if you enable history backup.
- Audio is transcribed on-device by Apple's Speech framework.
- Screenshots are captured locally through ScreenCaptureKit.
- Repo indexing is entirely local. Only the snippets matched by a question are
  sent to a model, never the whole codebase. Cloud review is the exception: it
  runs inside Cursor by design.
- Session history is written to a local SQLite database in Application Support.
  Backup to Neon Postgres is off unless you enable it and provide a URL.


## Project structure

```
install.sh                        one-line installer
.env.example                      environment template
project.yml                       XcodeGen project spec
WABusiness/
  WABusinessApp.swift             app entry point
  AppDelegate.swift               menu bar and window management
  OverlayWindowController.swift   floating transparent overlay
  Info.plist                      permission declarations
  WABusiness.entitlements         entitlements
  Services/
    EnvConfig.swift               env file parsing and lookup order
    AppViewModel.swift            core state and answer orchestration
    ModelRouter.swift             modes, provider chains, prompts
    GPTService.swift              OpenAI-compatible streaming client
    BedrockService.swift          AWS Bedrock streaming client
    ProviderHealth.swift          launch-time latency checks and muting
    RepoIndex.swift               local BM25 codebase index and retrieval
    RepoFetcher.swift             git clone and pull, repo URL parsing
    CursorAgentService.swift      Cursor cloud agent client
    SpeechRecognizer.swift        Apple Speech framework wrapper
    SystemAudioCapture.swift      system audio capture
    SilenceDetector.swift         pause detection for hands-free mode
    ScreenshotCapture.swift       ScreenCaptureKit integration
    StyleRecorder.swift           voice sample recording
    HotkeyManager.swift           global keyboard shortcuts
    SessionStore.swift            local SQLite session log
    NeonSync.swift                optional Neon Postgres backup
    ConversationTurn.swift        conversation history model
  Views/
    ContentView.swift             overlay bar and mode pills
    SetupView.swift               session setup
    AnswerView.swift              answer panel and tabs
    HistoryView.swift             session history dashboard
    MarkdownView.swift            Markdown rendering
```


## Contributing

1. Fork the repository.
2. Create a feature branch: `git checkout -b feature/your-change`
3. Commit your changes.
4. Push the branch.
5. Open a pull request.


## License

MIT. See the LICENSE file.
