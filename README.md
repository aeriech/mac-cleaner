# Mac Cleaner

A small, free Mac app that frees up disk space and tidies your Mac:

- **Smart Clean**: empties caches, logs, broken downloads and the Trash
- **Large & Old Files**, **Duplicates**, **Similar Images**: find files you no longer need
- **Uninstaller** and **Leftovers**: remove apps along with the files they leave behind
- **Performance**, **Background Items**: see what's running and what starts at login
- **Storage**: see what's using your disk

Anything it removes goes to the Trash first, so you can put it back if you change your mind.

**Requires macOS 14 (Sonoma) or newer.**

---

## Install (easy way: download)

> The download only works on Macs with Apple chips (M1, M2, M3 and so on). If your Mac has an Intel chip, use [Build it yourself](#install-build-it-yourself) below.
> To check which chip you have: Apple menu  → **About This Mac** → look at **Chip**.

1. Go to the [**Releases**](https://github.com/aeriech/mac-cleaner/releases/latest) page and download **Mac-Cleaner.zip**.
2. Double-click the zip to unzip it.
3. Drag **Mac Cleaner** into your **Applications** folder.
4. Open it. The first time, macOS will say it can't verify the app (it isn't from the App Store). That's expected:
   - Click **Done** (or **OK**).
   - Open **System Settings** → **Privacy & Security**, scroll down, and click **Open Anyway** next to "Mac Cleaner was blocked".
   - Confirm with your password or Touch ID, then click **Open**.

   You only have to do this once.

<details>
<summary>"Mac Cleaner is damaged and can't be opened"?</summary>

macOS sometimes shows this for downloaded apps that aren't from the App Store. Open **Terminal** (press ⌘ + Space, type `Terminal`), paste this line, and press Return:

```bash
xattr -dr com.apple.quarantine "/Applications/Mac Cleaner.app"
```

Then open the app again.
</details>

## Install (build it yourself)

Works on any Mac, Apple chip or Intel. It takes about 5 minutes.

1. Open **Terminal** (press ⌘ + Space, type `Terminal`).
2. Install Apple's free developer tools (skip this if you already have them). If a window pops up, click **Install**, and wait for it to finish:
   ```bash
   xcode-select --install
   ```
3. Download and build the app. It installs into your Applications folder:
   ```bash
   git clone https://github.com/aeriech/mac-cleaner.git
   cd mac-cleaner
   ./build.sh --install
   ```
4. Open **Mac Cleaner** from Applications or Launchpad.

## Let it see all your files (recommended)

macOS blocks apps from some folders, like Mail, Safari, and other apps' data, until you allow it. Without this, Smart Clean skips those folders and shows an **Allow access…** button.

1. Open **System Settings** → **Privacy & Security** → **Full Disk Access**.
2. Click **+**, choose **Mac Cleaner** from Applications, and switch it on.
3. Quit and reopen Mac Cleaner.

## Uninstall

Drag **Mac Cleaner** from Applications to the Trash.

## Command-line version

`macsweep.sh` does a quick cache, log and Trash cleanup from Terminal without the app. It only shows a report unless you add `--clean`:

```bash
./macsweep.sh          # just show what could be cleaned
./macsweep.sh --clean  # clean it, after asking you to confirm
```
