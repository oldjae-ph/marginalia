# Marginalia AI

A KOReader plugin: an AI reading companion for a jailbroken Kindle, using Claude.
Forked from [xray.koplugin](https://github.com/ultimatejimmy/xray.koplugin) (MIT).
It replaces both xray.koplugin and AI Dictionary on the device.

Full spec: https://claude.ai/artifact/UK6X356vQZ8icHHtbnSNVC
Screen mockups: https://claude.ai/artifact/F335WDiR53ZBcPKSGMpTFW

## Target environment

- Kindle Paperwhite 12th gen (PW6), firmware 5.19.6, jailbroken with Véra
- KOReader with the ZenOS interface plugin (zen_ui.koplugin) installed
- DRM-free EPUBs only
- Owner reads literary classics and a wide range of other novels (mystery, fantasy, contemporary, series)
- Personal use first; may be published later

## What Marginalia adds to xray.koplugin

1. **Reading guide**: offered the first time a book is opened. Spoiler-free intro; detects genre.
2. **Confirmed spoiler boundary**: auto within a chapter; the reader confirms to cross into the next. Replaces xray's automatic fetch on new chapter.
3. **Chapter debrief**: built on xray's chapter timeline. Two outputs: display text + a saved chapter record (JSON). Genre-specific format.
4. **Explain button**: replaces AI Dictionary. Names open the X-Ray character card; anything else gets an adaptive explanation (word, idiom/allusion, passage, dialogue).
5. **Character card extras**: importance label (Major / Supporting / Minor), aliases, chapter-by-chapter changes, "since last X-Ray update" line.

## Non-negotiable rules (spoiler invariants)

These are the product. Never weaken them to make a feature easier.

- Nothing past the **confirmed boundary** may enter any request: no book text, no X-Ray data, no chapter records. Enforce in code (context builder), not only in prompts.
- X-Ray content generated past the confirmed boundary (e.g. reader skimmed ahead) must not be shown or sent. Fall back to chapter records + current-chapter search.
- Jumps (TOC, endnotes, flipping ahead) never move the boundary. Only sequential reading moves the auto position; only the reader moves the confirmed boundary.
- Prompts must ban forward hints ("keep an eye on", "this matters later", "returns", "becomes", "turns out").
- Mystery/thriller genre in Strict mode: no theories about the solution, even when asked.
- Importance label: label only, never the reason.
- Chapter records are written within the boundary at the time, so stored memory can never contain spoilers. Keep it that way.

## Code conventions

- Keep Marginalia code in its own modules (prefix `marginalia_`). Touch upstream xray files only where a hook is needed, and keep those diffs small: we want to merge upstream updates later.
- Prompt templates live in separate files, one per task: reading guide, debrief (per genre), explain, card update, spoiler check.
- Plugin folder: `marginalia.koplugin`. Use its own settings keys and storage paths so it can run alongside xray.koplugin during migration.
- API keys never go in source, logs or reading-history files.
- Never log full book text.
- Long requests must not freeze the UI: background request + loading indicator.
- E-ink UI: black and white, large touch targets (44px+), minimal redraws, no animation.

## Models used by the plugin

| Feature | Model |
| --- | --- |
| Reading guide, debriefs, open questions | `claude-sonnet-5-5` |
| Explain popup, card updates | `claude-sonnet-5-5` (or `claude-haiku-5-5` for speed) |
| Spoiler check (second pass) | `claude-haiku-5-5` |

Check how xray.koplugin selects Claude models; add these if they aren't listed.

## Testing

**Unit tests (busted):** xray.koplugin has a `spec/` folder. Put Marginalia tests there too. Logic that must be unit-tested without the UI:
- boundary manager (auto position, confirm, roll back, ignore jumps)
- context builder (never includes anything past the boundary)
- chapter record read/write and corruption safety (a failed request must not corrupt saved records)
- selection router (word / name / place / passage / dialogue)

**Emulator (manual + scripted checks):** KOReader desktop emulator, sized like the Paperwhite (1264×1680, 300 dpi) at half scale:

```
./kodev run -w=632 -h=840 -d=150
```

Setup depends on the host OS:
- **Linux / macOS:** clone koreader, `./kodev fetch-thirdparty`, `./kodev build`, then `./kodev run` with the flags above.
- **Windows:** use WSL (Ubuntu) and do the Linux steps there, or run the KOReader Linux AppImage in WSL the way xray.koplugin's `run_koreader.bat` does. Needs WSLg or an X server.
- Symlink or copy `marginalia.koplugin` into the emulator's `plugins/` folder.

**Test books** (DRM-free): Project Gutenberg EPUBs of *The Idiot* (Garnett translation), *The Hound of the Baskervilles* (mystery), plus one recent DRM-free novel the owner provides.

**Spoiler test set** (gate for release): 2 classics, 1 mystery, 1 recent novel; 10 spoiler-tempting questions each at three boundary points. Target: zero plot reveals.

## Deploying to the Kindle

- Plugin path on device: `/mnt/us/koreader/plugins/marginalia.koplugin/`
- KOReader has a built-in SSH server (Tools > Network > SSH server). With it on, copy builds over Wi-Fi with `scp`/`rsync` instead of USB. Ask the owner for the Kindle's IP and confirm before copying anything to the device.
- Restart KOReader after copying.

## Working with the owner

- Communication style: direct and brief. Report findings as short bullets or tables.
- Flag gaps and risks honestly; don't paper over unknowns.
- Ask before large refactors of upstream code, before deleting anything, and before touching the device.
- Commit in small steps with clear messages.
