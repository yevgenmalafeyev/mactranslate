# mTranslate

Menu-bar app: select text anywhere, press **⌘C ⌘C** quickly → popup with translation, word list and clickable word cards (via local `claude` CLI).

- Tabs: one per target language (⌘1…⌘9) + last tab explaining the snippet in its own language. Portuguese is always pt-PT.
- Click any word (or a word-list row) → full card: POS, gender, IPA, forms, all meanings, examples, pronunciation, images (Pixabay → Pexels → Wikipedia/Commons → Openverse).
- ESC: card → back; snippet → close. ⌘W closes.
- In-flight translations finish in the background and land in History (SQLite at `~/Library/Application Support/mTranslate/`).

## Install
1. Download `mTranslate-<version>.dmg` from [Releases](https://github.com/yevgenmalafeyev/mtranslate/releases/latest) (universal: Apple silicon + Intel, macOS 15+).
2. Open it and drag **mTranslate** onto **Applications**.
3. Open **mTranslate** from Applications. The app is signed with a Developer ID and notarized by Apple, so it opens normally.
4. Grant **Input Monitoring** when asked (needed to detect ⌘C ⌘C), and make sure the `claude` CLI is installed and logged in.

## Build
    ./build.sh install            # release build, sign, install to ~/Applications, launch
    ./build.sh dmg                # universal build, Developer ID signed, notarized + stapled build/mTranslate-<version>.dmg
    swift test                    # core unit tests
    swift run mtprobe "text" --target ru [--mono pt] [--card word]   # CLI probe of prompts/parser
    open "mtranslate://translate?text=Hello"                        # show the popup without the hotkey (asks before translating)
    swift Scripts/make_icon.swift # regenerate Resources/AppIcon.icns

Logs: `/usr/bin/log stream --predicate 'subsystem == "local.mtranslate.app"'`
Reset permission: `tccutil reset ListenEvent local.mtranslate.app`

## Requirements
- macOS 15+, Xcode / Swift 6 toolchain
- [Claude Code CLI](https://docs.claude.com/claude-code) installed and logged in. `claude` is looked up in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`, `/usr/bin`, `/bin` and `~/.claude/local`, in that order (symlink it into one of them if it lives elsewhere); the path is fixed, not a setting
- Optional: Pixabay API key (Configuration → Images) for better pictures

## Signing
Create a gitignored `build.local.sh` with your identity so the Input Monitoring permission survives rebuilds:

    IDENTITY="Apple Development: Your Name (TEAMID)"

Without it the app is signed ad-hoc and macOS may ask for the permission again after each rebuild.

`./build.sh dmg` signs with your "Developer ID Application" certificate (hardened runtime, secure timestamp), signs the DMG, submits it to Apple's notary service, staples the ticket and prints the SHA-256. It needs notarytool credentials in a keychain profile (`xcrun notarytool store-credentials`); set `NOTARY_PROFILE` / `DIST_IDENTITY` in `build.local.sh` if yours differ from the defaults, or `NOTARIZE=0` to skip notarization.

## Security notes
- An `mtranslate://` link only shows its text and asks; nothing is sent to Claude or saved until you click **Translate**.
- `claude` runs with no tools, no MCP servers, no skills or slash commands, no user/project settings and no saved sessions; text goes in on standard input. It is started without this app's privacy permissions (so it cannot use Input Monitoring), with a minimal environment, in an empty private folder.
- Translated text is kept in the history database (`~/Library/Application Support/mTranslate/store.sqlite`) until you delete entries in History. The file is closed to other user accounts but, like the clipboard itself, not to other programs running as you; it is not encrypted. Image API keys are in the Keychain.
- Clipboard-watch mode has to be chosen in Configuration; changing the stored setting from outside doesn't enable it.

## License
MIT — see [LICENSE](LICENSE). Images shown in the app come from third-party providers under their own licenses (credited in the UI).
