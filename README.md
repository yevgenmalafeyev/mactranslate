# mTranslate

Menu-bar app: select text anywhere, press **⌘C ⌘C** quickly → popup with translation, word list and clickable word cards (via local `claude` CLI).

- Tabs: one per target language (⌘1…⌘9) + last tab explaining the snippet in its own language. Portuguese is always pt-PT.
- Click any word (or a word-list row) → full card: POS, gender, IPA, forms, all meanings, examples, pronunciation, images (Pexels → Wikipedia/Commons → Openverse).
- ESC: card → back; snippet → close. ⌘W closes.
- In-flight translations finish in the background and land in History (SQLite at `~/Library/Application Support/mTranslate/`).

## Install
1. Download `mTranslate-<version>.dmg` from [Releases](https://github.com/yevgenmalafeyev/mtranslate/releases/latest) (universal: Apple silicon + Intel, macOS 15+).
2. Open it and drag **mTranslate** onto **Applications**.
3. The app isn't notarized by Apple, so the first launch is blocked. Open it once, then go to **System Settings → Privacy & Security → Open Anyway**. Or run `xattr -dr com.apple.quarantine /Applications/mTranslate.app`.
4. Grant **Input Monitoring** when asked (needed to detect ⌘C ⌘C), and make sure the `claude` CLI is installed and logged in.

## Build
    ./build.sh install            # release build, sign, install to ~/Applications, launch
    ./build.sh dmg                # universal build + build/mTranslate-<version>.dmg
    swift test                    # core unit tests
    swift run mtprobe "text" --target ru [--mono pt] [--card word]   # CLI probe of prompts/parser
    open "mtranslate://translate?text=Hello"                        # trigger popup without the hotkey
    swift Scripts/make_icon.swift # regenerate Resources/AppIcon.icns

Logs: `/usr/bin/log stream --predicate 'subsystem == "local.mtranslate.app"'`
Reset permission: `tccutil reset ListenEvent local.mtranslate.app`

## Requirements
- macOS 15+, Xcode / Swift 6 toolchain
- [Claude Code CLI](https://docs.claude.com/claude-code) installed and logged in (`claude`)
- Optional: Pixabay API key (Configuration → Images) for better pictures

## Signing
Create a gitignored `build.local.sh` with your identity so the Input Monitoring permission survives rebuilds:

    IDENTITY="Apple Development: Your Name (TEAMID)"

Without it the app is signed ad-hoc and macOS may ask for the permission again after each rebuild.

## License
MIT — see [LICENSE](LICENSE). Images shown in the app come from third-party providers under their own licenses (credited in the UI).
