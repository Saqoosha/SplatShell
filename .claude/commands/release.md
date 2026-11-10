# Release SplatShell

Release a new version of SplatShell with automatic version bump and release notes.

## Task

### 1. Get current version and changes

```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist

# Previous tag
git tag --sort=-version:refname | head -1

# Diff from the previous tag (or the whole history if there is no tag)
git diff <previous_tag>..HEAD
```

### 2. Analyze the diff and determine the version bump

- **Major (X.0.0)**: Breaking changes, major rewrites
- **Minor (X.Y.0)**: New features, significant improvements; a new SuperSplat version
- **Patch (X.Y.Z)**: Bug fixes, small improvements, documentation, refactoring, build and release scripts

When in doubt, use Patch.

### 3. Run the release script

```bash
MODEL_NAME="<your model name>" ./scripts/release.sh <new_version>
```

Set `MODEL_NAME` to your actual model name for the Co-Authored-By line of the release commit.

This builds, signs, notarizes, creates the DMG, commits, tags, pushes and creates the GitHub Release. It needs the Developer ID certificate and the `notarytool-profile` credentials on this Mac; `scripts/package_dmg.sh` stops with an error when the certificate is missing.

### 4. Generate release notes from the diff

Analyze the actual code changes and write user-facing release notes:

```markdown
### Features (if new features added)
- New feature description

### Changes (if improvements made)
- Change or improvement description

### Bug Fixes (if bugs fixed)
- Fixed issue description
```

- Do NOT include a top-level title (e.g. `## SplatShell X.Y.Z`): GitHub already shows the release title
- Do NOT include a Requirements section
- Bug Fixes lists only bugs that existed in the previous released version, not ones fixed while building a feature of this release
- Describe user-visible changes, not implementation details
- Release notes are written in English

### 5. Update the GitHub Release

```bash
gh release edit v<new_version> --notes "<generated notes>"
```

### 6. Update the Sparkle appcast

After the release notes are final, so Sparkle shows them:

```bash
./scripts/update_appcast.sh <new_version>
```

### 7. Show the result

- New version number
- Release URL: `https://github.com/Saqoosha/SplatShell/releases/tag/v<new_version>`
