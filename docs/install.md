# Installing Deiko

Deiko needs macOS 14 or later on Apple silicon.

## One line (recommended)

```sh
curl -fsSL https://deiko.app/install.sh | sh
```

This downloads the latest release, copies it to `/Applications`, clears the
download quarantine and launches it. [Read the script first](../scripts/install.sh);
it is short.

## From the disk image

1. Drag **Deiko** onto the Applications folder.
2. Before launching, clear the quarantine once:

   ```sh
   xattr -dr com.apple.quarantine /Applications/Deiko.app
   ```

   Deiko is signed with its own certificate rather than an Apple Developer ID,
   so macOS quarantines the download. This clears the whole bundle, including
   the Node runtime Deiko uses to transcribe. "Open Anyway" in System Settings
   starts the app but can leave that runtime quarantined; right-click → Open is
   not enough on current macOS.
3. Launch it. Deiko lives in the menu bar, and a first-run window asks for four
   permissions:

   | Permission | Used for |
   |---|---|
   | Accessibility | reading the label under your cursor, and the hotkey |
   | Screen Recording | cropping what you point at (needs a relaunch) |
   | Microphone | recording your narration while a session runs |
   | Speech Recognition | on-device transcription |

## Updating

Run the install line again. Your permissions and briefs are kept. Deiko also
checks for a newer release at launch and adds an **Update to …** item to its
menu; it never installs anything by itself.

## Uninstalling

Quit Deiko and turn off **Open Deiko at login** in Settings, then:

```sh
rm -rf /Applications/Deiko.app
rm -rf ~/Library/Application\ Support/Deiko   # your briefs and screenshots
rm -rf ~/Library/Logs/Deiko
defaults delete com.deiko.capture
security delete-generic-password -s com.deiko.capture -a GROQ_API_KEY 2>/dev/null
tccutil reset All com.deiko.capture
```
