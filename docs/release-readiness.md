# Public-Release Readiness Checklist

This document tracks the remaining limitations of the ad-hoc signed
`2.1.0-rc4` build and the exact steps required to turn it into a publicly
distributable macOS release. It is an honest audit, not a claim that any of
these steps have been performed. No Apple credentials, signing identities, or
external uploads are stored in this repository.

## Current state (rc4)

| Dimension | State | Evidence |
| --- | --- | --- |
| Code signature | Ad-hoc only (`Signature=adhoc`, `TeamIdentifier=not set`) | `codesign -dvvv` on rc4 bundle |
| Gatekeeper | Rejected (`spctl -a -vvv -t exec` exit 3) | Expected for ad-hoc builds |
| Notarization | Not performed (no notarytool ticket) | `xcrun stapler validate` returns "no ticket" |
| Architecture | arm64 only (Apple silicon) | `lipo -info` confirms non-fat Mach-O |
| SBOM | Content manifest (integrity inventory) + CycloneDX SBOM generator | `Scripts/generate-sbom.sh`, `Contents/Resources/content-manifest.txt` |
| CI | Build + test workflow present; release job had a path bug (fixed this segment) | `.github/workflows/ci.yml` |
| User-open instructions | Documented in README (right-click → Open, `xattr -d`) | `README.md` |
| Repo hygiene | `.gitignore` added; no `.git` directory yet; no `LICENSE` file yet | This document |

## 1. Developer ID signing and notarization

The build script already supports the public-distribution path. The missing
piece is Apple credentials, which are not and will not be stored in this repo.

### Prerequisites (user must obtain)

1. **Apple Developer Program membership** — https://developer.apple.com/programs/
   ($99/year). Membership grants a Team ID and the ability to create Developer
   ID certificates.
2. **Developer ID Application certificate** — In Keychain Access or
   https://developer.apple.com/account, create a "Developer ID Application"
   certificate. The signing identity string has the form:
   `Developer ID Application: Your Name (TEAMID)`.
3. **Notarytool keychain profile** — Store Apple ID credentials for notarytool:
   ```bash
   xcrun notarytool store-credentials "parallax-notary" \
       --apple-id "you@example.com" \
       --team-id "TEAMID" \
       --password "app-specific-password"
   ```
   Requires an app-specific password from https://appleid.apple.com.
   Alternatively, use an App Store Connect API key with `--key` / `--key-id`
   / `--issuer`.

### Build command (once credentials are obtained)

```bash
./Scripts/build-release.sh \
    --version 2.1.0 \
    --sign "Developer ID Application: Your Name (TEAMID)" \
    --notarize \
    --notary-profile "parallax-notary" \
    --output ./dist
```

The script signs with `--options runtime --timestamp` (hardened runtime +
secure timestamp), submits the DMG via `xcrun notarytool submit --wait`,
staples the ticket with `xcrun stapler staple`, and validates it. A
notarized build passes `spctl -a -vvv -t open` on a clean Mac.

### Verification (after a notarized build)

```bash
spctl -a -vvv -t open ./dist/Parallax-2.1.0.dmg   # should say "accepted"
xcrun stapler validate ./dist/Parallax-2.1.0.dmg   # should say "Ticket found"
```

## 2. Universal 2 feasibility

The rc4 build is arm64 only. A Universal 2 (arm64 + x86_64) build is feasible
but requires one of:

- **An Intel Mac** — Build an x86_64 slice on an Intel Mac, then merge with
  the arm64 slice using `lipo`:
  ```bash
  lipo -create -output ParallaxApp-universal ParallaxApp-arm64 ParallaxApp-x86_64
  ```
  Then run `build-release.sh --skip-build` against the merged binary (the
  script would need a `--binary` override, which it does not currently have).
- **A two-machine build** — Same as above but across two machines, with the
  x86_64 slice transferred to the Apple-silicon machine for merging.
- **Rosetta-based cross-compile (not recommended)** — `swift build --arch
  x86_64` on Apple silicon can produce an x86_64 slice, but SceneKit/Metal
  GUI apps are not reliably cross-compilable this way. Test thoroughly before
  trusting it.

macOS does not support native cross-compilation of GUI app bundles from
arm64 to x86_64 on Apple silicon. The reliable path is an Intel Mac (or a
two-machine build). Intel Mac support is a product decision, not a script
limitation — the build script will package whatever binary it is given.

If Intel support is not a goal, document "Apple silicon only" in the README
and release notes (already done).

## 3. SBOM (Software Bill of Materials)

`Scripts/generate-sbom.sh` produces a CycloneDX 1.5 JSON document covering:

- The package name, version, and supplier
- All SPM targets (components) with their types
- External dependencies (none — `Package.swift` declares no external
  dependencies)
- The Swift toolchain version and macOS deployment target
- A reference to the content manifest for bundled-file hashes

```bash
./Scripts/generate-sbom.sh --version 2.1.0-rc4 --output ./dist/parallax-sbom.json
```

The SBOM is a dependency/component inventory. The content manifest
(`Contents/Resources/content-manifest.txt`) remains the integrity inventory
for bundled files. They are complementary:

| Document | Purpose | Scope |
| --- | --- | --- |
| `content-manifest.txt` | Integrity (SHA-256 + size per bundled file) | Bundle contents |
| `parallax-sbom.json` | Component/dependency inventory (CycloneDX 1.5) | SPM package + toolchain |

## 4. CI and test commands

The CI workflow (`.github/workflows/ci.yml`) runs on every push to `main` /
`develop` and on PRs to `main`. It builds, tests, runs the bot benchmark,
validates boards, and (on tag pushes) builds a release DMG.

### Local test commands (run before declaring a release ready)

```bash
# Full Swift test suite (414 tests, 12 AX-gated skips expected in headless runs)
swift test -j 2

# Packaging script tests (39 tests, no Swift build required)
/bin/bash Scripts/test-build-release.sh

# Bundle verification on a built app
./Scripts/verify-bundle.sh ./dist/Parallax.app

# Offscreen board render checks (real SceneKit scene, not desktop interaction)
swift run parallax-render-check triad /tmp/parallax-triad.png 1200 600
swift run parallax-render-check grandmaster /tmp/parallax-grandmaster.png 1200 600

# Board validation
swift run parallax-tools validate-board triad
swift run parallax-tools validate-board grandmaster

# Bot benchmark
swift run parallax-tools benchmark

# SBOM generation
./Scripts/generate-sbom.sh --version 2.1.0-rc4 --output ./dist/parallax-sbom.json
```

The 12 headless skips are `AXIsProcessTrusted=false` (AX tree not materialized)
and one headless-window skip (real key event dispatch needs a key window).
These are not regressions — they have been present since Segments 7/13/15 and
require Accessibility trust or a GUI session to exercise.

## 5. Gatekeeper and user-open instructions

The rc4 DMG is ad-hoc signed. On a Mac with Gatekeeper enforced, opening it
requires one of:

### Option A — Right-click → Open (GUI)

1. Open the DMG and drag **Parallax.app** to **Applications**.
2. In Finder, right-click (or Control-click) **Parallax.app** → **Open**.
3. Click **Open** in the Gatekeeper dialog. This creates a one-time launch
   exception for the ad-hoc signature.

### Option B — Remove quarantine attribute (Terminal)

```bash
xattr -dr com.apple.quarantine /Applications/Parallax.app
```

This removes the quarantine flag that triggers Gatekeeper. The app then
launches normally. Use this only for builds you trust.

### Option C — Developer ID + notarization (public distribution)

Once the build is Developer ID signed and notarized (see section 1), no
Gatekeeper dialog appears and no `xattr` command is needed. This is the
path for public distribution to users who do not know the developer.

## 6. Repository handoff hygiene

### What is present

- `.gitignore` — ignores `.build/`, `dist/`, build artifacts, macOS metadata,
  and the stray `logs/` directory.
- `docs/`, `Scripts/`, `Sources/`, `Tests/`, `Package.swift`, `README.md` —
  all source and documentation is present.
- `.github/workflows/ci.yml` — CI workflow with build, test, and release jobs.

### What is missing (handoff items for the user)

| Item | Why it matters | Action |
| --- | --- | --- |
| `.git` directory | The project is not a git repository. CI and release tags require git. | `git init`, initial commit, push to a GitHub/GitLab remote. |
| `LICENSE` file | No software license is declared. Public distribution without a license defaults to "all rights reserved." | Add a permissive license (MIT, Apache-2.0) for the original code. The fan-project disclaimer in `docs/licensing-and-attribution.md` covers the Star Trek inspiration but is not a software license. This is a legal decision for the user. |
| `logs/mac-ai-os.log` | Stray MAOS MCP server log (ListPromptsRequest spam). Not part of the project. | Delete or leave gitignored. |

### Handoff checklist

```bash
# 1. Initialize git
cd /Users/david/Projects/parallax
git init
git add .
git commit -m "Initial public release candidate (2.1.0-rc4)"

# 2. Add a LICENSE file (user decision — see table above)

# 3. Push to a remote
git remote add origin <your-remote-url>
git push -u origin main

# 4. Tag the release
git tag v2.1.0-rc4
git push origin v2.1.0-rc4

# 5. CI will build and upload the DMG artifact on the tag push
```

## Summary

The rc4 build is feature-complete and tested (414 Swift tests, 39 packaging
tests, 0 failures). The remaining gaps are release-engineering, not product:

1. **Signing/notarization** — requires Apple credentials (user obtains).
2. **Universal 2** — requires an Intel Mac or two-machine build (product
   decision).
3. **SBOM** — generator script added this segment; run it as part of the
   release process.
4. **CI** — workflow fixed this segment; test commands documented above.
5. **User-open instructions** — documented in README and this file.
6. **Repo hygiene** — `.gitignore` added; `git init` and `LICENSE` are user
   handoff items.

No step in this document requires mutating external services. The Apple
credential steps are performed by the user on their own machine.
