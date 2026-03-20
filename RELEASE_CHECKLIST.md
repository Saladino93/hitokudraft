# Release Checklist

## Pre-flight
- [ ] Build succeeds: `xcodebuild -scheme HitokuDraft -destination 'platform=macOS' build`
- [ ] Test all three hotkeys (Voice Edit, Grammar Fix, Dictation)
- [ ] Clipboard content preserved after each operation
- [ ] No regressions in Settings UI

## Changelog
- [ ] Update `CHANGELOG.md` with new version entry
- [ ] Update public changelog at hitokume docs site

## Release
- [ ] Run `./release.sh <version>`
- [ ] Upload new DMG to Gumroad product
- [ ] Commit + push hitokume site (changelog.html)
