# Sift — agent notes

Personal research library as a **native macOS app: Sift** — a
SwiftUI catalog: ingest, tag (LLM-assisted via Claude CLI or Ollama, optional),
rate, read/unread, save/bookmark, search, delete. **Positioning:** fast native
alternative to clunky paper-management tools (Zotero, Mendeley, Papers/Readcube).
For engineers and researchers who want to **collect → tag → rate → recall**.
NOT a citation manager.

> **History:** this repo used to also host a Python CLI / FastAPI web app
> (`paper`, under `src/paper_manager/`) that did LLM-driven extras — Keshav
> summaries, Ollama embeddings, FTS+vector search, recommendation rows, arXiv
> discovery, and static-site export to randomstorms.net/papers/. It was removed
> on 2026-06-01 (recover from git history if needed). The public-site export may
> return later as a separate tool. The repo directory is still named
> `paper_manager/` (legacy from before the Sift rebrand) — the local checkout
> dir name only; the product is **Sift**.

## Layout

Sift is the whole repo now — the Swift package lives at the root (it used to be
nested under `macapp/`; flattened on 2026-06-02 after the Python CLI was
removed).

```
Package.swift             SPM manifest (executable target SiftApp, path Sources/SiftApp)
Sources/SiftApp/
  SiftApp.swift           @main entry
  Models/                 Paper, Prefs (Codable mirrors of metadata.json/prefs.json)
  Views/                  RootView, Sidebar, PaperList, PaperDetail, AddSheet,
                          SettingsView, WelcomeView, ConsolidateTagsSheet
  Services/               LibraryStore, IngestService, Config, LLMTagger, TagStore
build.sh                  ./build.sh {release|debug|run|dmg} — produces Sift.app / Sift-VER.dmg
Resources/Info.plist      Bundle metadata, version. CFBundleIdentifier net.randomstorms.Sift
docs/                     Landing/distribution page served via GitHub Pages
README.md                 Full user-facing install / usage guide
```

## Data lives in iCloud, not the repo

```
<library>/   (default: ~/Library/Mobile Documents/com~apple~CloudDocs/PaperManager/)
├── library/<paper_id>/  paper.pdf, metadata.json, summary.md, figures/
├── user/                prefs.json
├── inbox/               drop PDFs here → ⌘R to ingest
└── tags.json            library-wide tag vocabulary (Sift TagStore writes it)
```

The default on-disk folder is still named `PaperManager/` even though the app is
Sift — kept that way so existing libraries round-trip unchanged. Users can
choose any folder; the app uses whichever folder is configured.

`paper_id` is derived from the SHA-256 of the PDF **at ingest time** — same file
ingested twice is a no-op. The files in iCloud are the source of truth; there is
no separate database to migrate.

> **Note (0.6):** the reader writes highlight annotations into `paper.pdf`
> itself (so they sync and show in Preview), which means a paper's on-disk bytes
> can drift from the `sha256`/`paper_id` recorded at ingest. This is fine —
> dedupe compares a *source* file's hash to stored `metadata.sha256`, never
> re-hashes `paper.pdf` — but don't assume `SHA-256(library/<id>/paper.pdf) == id`
> for a paper that's been highlighted.

## Key invariants

- **iCloud files are canonical.** Any new persistent field must round-trip
  through `metadata.json` / `prefs.json` / `tags.json`. The `summary.md` and
  `figures/` artifacts may exist from the old Python ingest; Sift reads
  `summary.md` if present but does not generate it.
- **Claude is invoked via the local `claude` CLI**, not the API. No
  `ANTHROPIC_API_KEY` needed.
- **Ollama on localhost:11434** for Sift's optional chat-model tagging path.
  Sift uses `/api/chat` with `think: false` and `num_predict: 1000` to avoid
  reasoning-token runaway on qwen3.5.
- **Four kinds**: `paper` | `book` | `report` | `poster` (poster added in 0.4.3).
- **Sift bundle ID**: `net.randomstorms.Sift`. UserDefaults keys are `Sift.*`.
  Notification names are `Sift.*`. Anything still under a `PaperManager.*`
  prefix is legacy and should be migrated when touched.
- **Folder two-field invariant.** A paper has both `auto.folder` (LLM-assigned)
  and `user_folder` (user override). `Paper.effectiveFolder` returns
  `user_folder ?? auto.folder`. The sidebar's *Folders* section, the
  `LibraryFilter.folder` filter, and `LibraryStore.allFolders` all use
  `effectiveFolder`. `LibraryStore.renameFolder(from:to:)` updates *both*
  fields when either matches the source name, so a rename or merge applies
  uniformly regardless of origin. `LibraryStore.runTagging` only writes
  `auto.folder`, never `user_folder` — re-running the tagger on a paper with
  a user override leaves the user's choice intact.
- **Sidebar owns operations, Settings owns configuration** (0.5.3). Folder
  management, author consolidation, and tag consolidation are reachable
  only from the sidebar — section-header icons and per-entry right-click.
  Settings shows counts and configuration knobs; no operation buttons.

## LLM operations

All LLM work flows through three chokepoints — add new LLM features via
these, never by calling providers directly:

- `LLMTagger.complete(prompt:using:)` — single provider dispatch (Claude CLI
  subprocess or Ollama `/api/chat`).
- `LLMTagger.jsonObject(from:)` — shared response cleanup (code fences,
  stray prose) + JSON parse; every response parser uses it.
- `LibraryStore.resolveProvider()` — provider resolution; also refreshes the
  published `llmProvider`/`llmDiagnostic` so Settings stays honest.
- Bulk operations share `LibraryStore.runBulk` (prime-and-refill task group,
  `bulkConcurrency` = 3, cancellable, main-actor progress callback).

`complete(prompt:using:expecting:)` takes a `ResponseFormat` — `.json` (default,
turns on Ollama JSON mode + tight cap) or `.text` (free-form Markdown, used by
reader Q&A).

| Operation | LLMTagger entry | Model | Trigger |
|---|---|---|---|
| Tag/extract (title, authors, summary, tags, folder) | `extractInfo` | user's pick | ingest, toolbar AI → Tag all, detail Re-extract / Generate tags |
| Attribution consensus (multi-pass title/authors) | `consensusTitleAuthors` | cheap (`cheapVariant`: haiku / local) | inside tagging when title/authors would change; toolbar AI → Verify attributions (library-wide) |
| Import triage of watched-folder PDFs | `assessImport` | user's pick | review sheet "Assess with AI" (advisory only) |
| Reader Q&A (grounded in PDF text) | `answerQuestion` (`.text`) | user's pick | reader chat panel; `LibraryStore.askPaper` |
| Tag merges | `proposeMerges` | user's pick | sidebar Tags ✨ |
| Author merges | `proposeAuthorMerges` (multi-pass via store) | user's pick | sidebar Authors ✨ |

Attribution rule: a title/author value is only written when two passes agree
(`consensusTitleAuthors`); no consensus → field left as-is.

## Common dev workflows

```bash
./build.sh run                           # build + launch Sift
./build.sh dmg                           # ship a release DMG (Sift-VER.dmg)
```

There is **no test suite**. Validate changes by ingesting a real PDF and
exercising the affected surface.

## Agents

`.claude/agents/` holds project-specific Claude Code subagents:
- `paper-manager-pm` — product/feature steward for Sift (still named
  `paper-manager-pm` for the agent invocation handle; content references the
  Sift product)
- `diva-engineer` — UI-detail critic, Steve-Jobs style
- `general-user` — first-time-user friction reviewer
- `paper-scout` — finds new papers via web grounded in tags.json
- `qa-reviewer` — pre-commit QA gate: builds, scans the diff for stray
  artifacts / leftovers / broken refs before anything is committed
- `web-designer` — builds & maintains the `docs/` GitHub Pages distribution
  site (writes HTML/CSS)
