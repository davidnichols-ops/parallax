#!/bin/bash
# generate-sbom.sh — Generate a CycloneDX 1.5 Software Bill of Materials for
# the Parallax Swift package.
#
# The SBOM documents the package name, version, supplier, all SPM targets
# (components) with their types and inter-target dependencies, the Swift
# toolchain version, the macOS deployment target, and confirms that no
# external package dependencies are declared. It complements the content
# manifest (Contents/Resources/content-manifest.txt), which is an integrity
# inventory of bundled files.
#
# Usage:
#   ./Scripts/generate-sbom.sh
#   ./Scripts/generate-sbom.sh --version 2.1.0-rc4 --output ./dist/parallax-sbom.json
#   ./Scripts/generate-sbom.sh --validate ./dist/parallax-sbom.json
#
# Exit codes:
#   0 = success
#   1 = validation/generation error
#   2 = usage error

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="2.0.0"
OUTPUT=""
VALIDATE=""
PACKAGE_NAME="parallax"
SUPPLIER="Parallax project (independent fan recreation)"

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  --output PATH          Write SBOM JSON to PATH (default: stdout)
  --version VERSION      Version string MAJOR.MINOR.PATCH (default: 2.0.0)
  --validate PATH        Validate an existing SBOM file and exit
  --help, -h             Show this help
EOF
}

require_arg() {
    local opt="$1" remaining="$2"
    if [[ "$remaining" -lt 1 ]]; then
        echo "ERROR: $opt requires an argument." >&2
        usage
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            require_arg "$1" $(($# - 1))
            OUTPUT="$2"; shift 2 ;;
        --version)
            require_arg "$1" $(($# - 1))
            VERSION="$2"; shift 2 ;;
        --validate)
            require_arg "$1" $(($# - 1))
            VALIDATE="$2"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 2
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Validate mode: check an existing SBOM file for CycloneDX 1.5 structure.
# ---------------------------------------------------------------------------
if [[ -n "$VALIDATE" ]]; then
    if [[ ! -f "$VALIDATE" ]]; then
        echo "ERROR: SBOM file not found: $VALIDATE" >&2
        exit 1
    fi
    python3 - "$VALIDATE" <<'PYEOF'
import json, sys, sys
path = sys.argv[1]
with open(path) as f:
    try:
        doc = json.load(f)
    except json.JSONDecodeError as e:
        print(f"ERROR: invalid JSON: {e}", file=sys.stderr)
        sys.exit(1)
errors = []
if doc.get("bomFormat") != "CycloneDX":
    errors.append("bomFormat is not CycloneDX")
if doc.get("specVersion") != "1.5":
    errors.append(f"specVersion is not 1.5 (got {doc.get('specVersion')!r})")
if "metadata" not in doc:
    errors.append("missing metadata")
else:
    md = doc["metadata"]
    if md.get("tools", {}).get("components") is None and not md.get("tools"):
        # CycloneDX 1.5 uses metadata.tools.components; 1.4 used metadata.tools
        pass
    comp = md.get("component", {})
    if comp.get("name") != "parallax":
        errors.append(f"metadata.component.name is not 'parallax' (got {comp.get('name')!r})")
    if comp.get("type") != "application":
        errors.append(f"metadata.component.type is not 'application' (got {comp.get('type')!r})")
comps = doc.get("components", [])
if not isinstance(comps, list) or len(comps) == 0:
    errors.append("components list is empty or missing")
else:
    names = {c.get("name") for c in comps}
    required = {"TacticalCore", "ParallaxApp"}
    missing = required - names
    if missing:
        errors.append(f"missing required components: {sorted(missing)}")
deps = doc.get("dependencies", [])
if not isinstance(deps, list):
    errors.append("dependencies is not a list")
# Confirm no external (non-target) dependencies are declared.
ext_deps = doc.get("properties", [])
has_external = any(p.get("name") == "parallax:externalDependencies" and p.get("value", "") not in ("", "none")
                    for p in ext_deps)
if has_external:
    errors.append("external dependencies are declared but should be none")
if errors:
    for e in errors:
        print(f"FAIL: {e}", file=sys.stderr)
    print(f"RESULT: FAIL ({len(errors)} error(s))", file=sys.stderr)
    sys.exit(1)
print(f"RESULT: PASS — SBOM valid ({len(comps)} components, {len(deps)} dependency edges)")
PYEOF
    exit $?
fi

# ---------------------------------------------------------------------------
# Generate mode
# ---------------------------------------------------------------------------
cd "$PROJECT_DIR"

# Get the SPM manifest as JSON via the official parser.
if ! MANIFEST_JSON="$(swift package dump-package 2>/dev/null)"; then
    echo "ERROR: 'swift package dump-package' failed. Run from the project root." >&2
    exit 1
fi

# Swift toolchain version (first line, e.g. "Apple Swift version 6.3.3 ...").
SWIFT_VERSION="$(swift --version 2>&1 | head -1 || echo 'unknown')"

# macOS deployment target from Package.swift (parse the .macOS(.vNN) line).
MACOS_TARGET="$(grep -oE '\.macOS\(\.v[0-9]+\)' Package.swift 2>/dev/null | head -1 | sed 's/\.macOS(\.v\([0-9]\+\))/\1.0/' || echo '14.0')"

# Generate the CycloneDX 1.5 document via python3 (always present on macOS).
SBOM_JSON="$(python3 - "$MANIFEST_JSON" "$VERSION" "$PACKAGE_NAME" "$SUPPLIER" "$SWIFT_VERSION" "$MACOS_TARGET" <<'PYEOF'
import json, sys, datetime, hashlib, uuid

manifest_raw, version, pkg_name, supplier, swift_ver, macos_target = sys.argv[1:7]
manifest = json.loads(manifest_raw)

# CycloneDX component type mapping from SPM target type.
# SPM types: "regular" (library), "executable" (executable), "test" (test).
type_map = {
    "regular": "library",
    "executable": "application",
    "test": "application",  # test targets are applications in CycloneDX terms
}

# Build components list from SPM targets.
components = []
target_names = set()
for t in manifest.get("targets", []):
    name = t["name"]
    target_names.add(name)
    ttype = t.get("type", "regular")
    deps = []
    for dep in t.get("dependencies", []):
        # dep can be {"byName": ["Name", ...]} or {"target": ["Name", ...]}
        # or {"product": [...]}. Only count target/byName deps as internal.
        if "byName" in dep:
            deps.append(dep["byName"][0])
        elif "target" in dep:
            deps.append(dep["target"][0])
    bom_ref = f"parallax@{version}/{name}"
    components.append({
        "type": type_map.get(ttype, "library"),
        "bom-ref": bom_ref,
        "name": name,
        "version": version,
        "purl": f"pkg:swift/parallax/{name}@{version}",
        "properties": [
            {"name": "parallax:targetType", "value": ttype},
            {"name": "parallax:sourcePath", "value": t.get("path", "")},
        ],
    })

# Build dependency edges (CycloneDX dependencies array).
dependencies = []
for t in manifest.get("targets", []):
    name = t["name"]
    bom_ref = f"parallax@{version}/{name}"
    dep_refs = []
    for dep in t.get("dependencies", []):
        dep_name = None
        if "byName" in dep:
            dep_name = dep["byName"][0]
        elif "target" in dep:
            dep_name = dep["target"][0]
        if dep_name and dep_name in target_names:
            dep_refs.append({"ref": f"parallax@{version}/{dep_name}"})
    dependencies.append({"ref": bom_ref, "dependsOn": dep_refs})

# Check for external (product) dependencies — should be none.
external_deps = []
for t in manifest.get("targets", []):
    for dep in t.get("dependencies", []):
        if "product" in dep:
            ext = dep["product"]
            external_deps.append(f"{ext[0]}/{ext[1]}" if len(ext) > 1 else ext[0])
external_value = ", ".join(sorted(set(external_deps))) if external_deps else "none"

# CycloneDX 1.5 document.
bom = {
    "bomFormat": "CycloneDX",
    "specVersion": "1.5",
    "serialNumber": f"urn:uuid:{uuid.uuid4()}",
    "version": 1,
    "metadata": {
        "timestamp": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "tools": {
            "components": [
                {
                    "type": "application",
                    "name": "Scripts/generate-sbom.sh",
                    "version": "1.0.0",
                }
            ]
        },
        "component": {
            "type": "application",
            "bom-ref": f"parallax@{version}",
            "name": pkg_name,
            "version": version,
            "supplier": {"name": supplier},
            "properties": [
                {"name": "parallax:swiftToolchain", "value": swift_ver},
                {"name": "parallax:macosDeploymentTarget", "value": macos_target},
                {"name": "parallax:externalDependencies", "value": external_value},
            ],
        },
    },
    "components": components,
    "dependencies": dependencies,
    "properties": [
        {"name": "parallax:contentManifest", "value": "Contents/Resources/content-manifest.txt (integrity inventory, generated by build-release.sh)"},
    ],
}

print(json.dumps(bom, indent=2))
PYEOF
)"

if [[ -z "$SBOM_JSON" ]]; then
    echo "ERROR: SBOM generation produced no output." >&2
    exit 1
fi

if [[ -n "$OUTPUT" ]]; then
    # Validate output parent directory.
    OUTPUT_PARENT="$(dirname "$OUTPUT")"
    if [[ ! -d "$OUTPUT_PARENT" ]]; then
        if ! mkdir -p "$OUTPUT_PARENT" 2>/dev/null; then
            echo "ERROR: cannot create output parent directory: $OUTPUT_PARENT" >&2
            exit 1
        fi
    fi
    if [[ ! -w "$OUTPUT_PARENT" ]]; then
        echo "ERROR: output parent not writable: $OUTPUT_PARENT" >&2
        exit 1
    fi
    printf '%s\n' "$SBOM_JSON" > "$OUTPUT"
    echo "SBOM written to: $OUTPUT ($(wc -c < "$OUTPUT") bytes)"
else
    printf '%s\n' "$SBOM_JSON"
fi
