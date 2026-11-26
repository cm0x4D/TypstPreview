# Typst Preview — Quick Look for `.typ`

A macOS Quick Look extension (pure Swift) that previews Typst documents:

- **Preview**: the document is rendered to PDF with your local `typst` (preferred) or `tinymist`, shown in PDFKit.
- **Source**: the Typst source with syntax highlighting (markup, code and math modes).
- A floating switch at the top toggles between the two views; the last choice is remembered.
- If neither tool is installed, an instruction page with `brew install typst` / `brew install tinymist` is shown.
- If compilation fails, the preview switches to the source, scrolls to the first error and marks the line
  (red line background, highlighted span, message as tooltip). A bar at the bottom shows the message,
  steps through multiple problems and opens the full compiler output (**Details**). Errors inside an
  `#include`d file are marked at the `#include` line.

## Build & install

```sh
xcodebuild -project TypstPreview.xcodeproj -scheme TypstPreview -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= build
cp -R build/Build/Products/Release/TypstPreview.app /Applications/
open /Applications/TypstPreview.app   # launch once to register the extension
qlmanage -r                            # reset Quick Look
```

Bundle identifiers derive from the project-level build setting `BUNDLE_ID_PREFIX`
(default `com.example`): `<prefix>.TypstPreview`, `<prefix>.TypstPreview.QuickLook`,
`<prefix>.TypstPreview.QuickLook.RenderService`. Set it and `DEVELOPMENT_TEAM` once at
the project level in Xcode.

Troubleshooting: if several copies of the app are registered (e.g. a Debug build plus an
installed one), Quick Look may pick either. List them with
`pluginkit -m -v -p com.apple.quicklook.preview | grep -i typst` and remove stale copies.

If the preview doesn't appear, enable **Typst Preview** in System Settings › General ›
Login Items & Extensions › Quick Look. Check with `pluginkit -m -i com.example.TypstPreview.QuickLook`.

## Architecture

| Target | Role |
|---|---|
| `TypstPreview` (app) | Host app, shows whether typst/tinymist was found; declares the `app.typst.document` UTI. |
| `TypstQuickLook` (appex) | `QLPreviewingController`: highlighting, PDF view, error pages, view switch. |
| `TypstRenderService` (xpc, inside the appex) | Runs the compiler. Quick Look extensions are not allowed to spawn processes (`EPERM`), XPC services are. |

The binaries are looked up in `/opt/homebrew/bin`, `/usr/local/bin`, `~/.cargo/bin`, `~/.local/bin`, `/opt/local/bin`.

### Sandbox entitlements (`Config/TypstRenderService.entitlements`)
- read-only access to the home folder, `/Volumes`, and the Homebrew/MacPorts prefixes, so that `#include`, images and user fonts work
- read-write access to `~/Library/Caches/typst` (shared package cache)
- outgoing network access for `@preview` package downloads

These are *temporary-exception* entitlements: fine for local or Developer ID distribution, but not accepted on the Mac App Store.

## Signing & notarization

Apps distributed outside the Mac App Store need a **Developer ID Application** certificate
and **notarization**; otherwise Gatekeeper blocks the downloaded app and the extension.
None of the entitlements used here require a provisioning profile.

### Local (Xcode)
1. Set `DEVELOPMENT_TEAM` and `BUNDLE_ID_PREFIX` in the project build settings.
2. Product › Archive › Distribute App › **Direct Distribution**. Xcode signs with Developer ID,
   notarizes and staples the app.

### GitHub Actions (`.github/workflows/build.yml`)

| Event | Result |
|---|---|
| pull request | unsigned build → artifact `TypstPreview-…-unsigned.zip` |
| push to `main`, manual run | signed + notarized build → artifact |
| tag `v1.2.3` | signed + notarized, version 1.2.3 → GitHub Release |

Without the secrets below every run builds unsigned.

**Repository variables** (Settings › Secrets and variables › Actions › Variables)

| Name | Value |
|---|---|
| `APPLE_TEAM_ID` | 10-character Team ID (developer.apple.com › Membership) |
| `BUNDLE_ID_PREFIX` | e.g. `ch.yourorg` |

**Repository secrets**

| Name | How to get it |
|---|---|
| `DEVELOPER_ID_CERTIFICATE_P12` | `base64 -i DeveloperID.p12 \| pbcopy` (see below) |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | password chosen when exporting the .p12 |
| `NOTARY_API_KEY_P8` | full text of `AuthKey_XXXXXXXXXX.p8` |
| `NOTARY_API_KEY_ID` | Key ID of that API key |
| `NOTARY_API_ISSUER_ID` | Issuer ID shown above the key list |

1. **Developer ID certificate:** Xcode › Settings › Accounts › your team › Manage Certificates ›
   + › *Developer ID Application*. Only the **Account Holder** can reliably create it
   (Admins may need *cloud-managed Developer ID* access, which can't be exported for CI).
   Then in Keychain Access › My Certificates, right-click “Developer ID Application: …” ›
   Export as .p12 with a password. The certificate *and* its private key must be included.
2. **Notary API key:** App Store Connect › Users and Access › Integrations ›
   App Store Connect API › Team Keys › generate a key (role *Developer* is intended to suffice;
   use *Admin* if notarytool returns 401). The .p8 can be downloaded only once.
3. Add the variables/secrets, push a tag: `git tag v1.0.0 && git push origin v1.0.0`.

The workflow imports the certificate into a temporary keychain, archives with
`CODE_SIGN_IDENTITY="Developer ID Application"` + hardened runtime + secure timestamp,
verifies there's no `get-task-allow`, notarizes with `notarytool --wait`, staples, checks
with `spctl`, and deletes the keychain afterwards.
