# Content Manifest

The content manifest is generated at build time by `Scripts/build-release.sh`
and stored inside the `.app` bundle at
`Contents/Resources/content-manifest.txt`.

## Format

Each line (excluding comments) is:

```
<sha256>  <size-bytes>  <relative-path>
```

- **sha256**: SHA-256 hash of the file content (`shasum -a 256`)
- **size-bytes**: File size in bytes (`stat -f%z`)
- **relative-path**: Path relative to the app bundle, beginning with `Contents/`

Comment lines begin with `#` and include the build version and timestamp.

## Purpose

1. **Integrity verification** — The build script re-hashes every file after
   assembly and compares against the manifest. Any mismatch fails the build.
2. **Tamper detection** — Run `Scripts/verify-bundle.sh` on a shipped bundle
   to confirm no files were altered after packaging.
3. **Content audit** — The manifest inventories unsigned resources and metadata
   with cryptographic fingerprints. The executable and signature are verified
   separately. No filler media is bundled.

## What gets bundled

Only meaningful, authored content is copied into the bundle:

| Resource | Description |
| --- | --- |
| `Contents/MacOS/ParallaxApp` | Compiled release executable |
| `Contents/Info.plist` | Bundle metadata with version stamps and icon provenance |
| `Contents/Resources/AppIcon.icns` | Original geometric app icon |
| `Contents/Resources/docs/rulebook.md` | Formal game rules |
| `Contents/Resources/docs/licensing-and-attribution.md` | Asset provenance and fan-project status |
| `Contents/Resources/docs/release-packaging.md` | Build documentation |
| `Contents/Resources/README.md` | Quick-start guide |
| `Contents/Resources/*.bundle` | SPM resource bundles (if Package.swift declares resources) |
| `Contents/Frameworks/*` | Swift runtime libraries (if needed) |

## Manifest vs code signature

The manifest is generated **before** code signing so the signature seals it
along with all other content. The main executable (`Contents/MacOS/ParallaxApp`)
is **excluded from the resource manifest**
because code signing embeds the signature into the Mach-O binary, changing its
hash. The executable's integrity is verified by `codesign --verify --deep
--strict` separately. All other files (resources, docs, Info.plist, icon) are
hash-verified against the manifest.

## What does NOT get bundled

- No dummy media or filler bytes
- No inflated duplicate files
- No episode video, audio, or actor images
- No actor portraits, character voice recordings, or episode dialogue
- No debug symbols or test fixtures

## Verification

```bash
# Verify a built bundle:
./Scripts/verify-bundle.sh dist/Parallax.app

# Inspect the manifest directly:
cat dist/Parallax.app/Contents/Resources/content-manifest.txt
```

The manifest is regenerated on every build. Previous builds' manifests are
preserved in the `.backup-*` directories alongside the recovered app bundles.
