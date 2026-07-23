# Changelog

Notable changes per release. One entry per minor version; patch releases
are folded in under the minor they belong to. For full per-release notes
including patches see [GitHub Releases](https://github.com/abhiramm7/sift/releases).

## 0.6 — Reader, watched folders, smarter attribution

- **Built-in reader (Read & Ask).** Double-click a paper (or ⇧⌘R) to open it
  in a tab: the PDF with savable text highlighting (four colors, written into
  the PDF itself so they sync and show in Preview), a jump-to table of
  contents from the PDF outline, and — with an AI helper connected — a chat
  that answers questions grounded in the paper, pre-loaded with its summary.
  Readers open as in-window tabs; Preview moved to the row's right-click menu.
- **Watched folders.** Point Sift at folders (e.g. Downloads) in Settings; it
  scans on launch and offers to import new PDFs it finds, de-duplicated
  against the library by content hash. Duplicates can be moved to the Trash.
  Optional **Assess with AI** reads each found PDF and recommends import/skip.
- **Multi-pass attribution.** Title/author extraction is verified by extra
  passes of a small model (haiku / local); a value is only written when two
  passes agree. Library-wide **Verify attributions** re-checks everything.
- **Duplicate detection.** Finds papers that are the same work stored more
  than once (arXiv id, DOI, or title match — not just byte-identical files).
  Surfaced via a banner and the sidebar Library header; the review sheet keeps
  the copy you pick and folds the others' tags and rating into it before
  trashing them.
- **Toggleable detail panel** (⌥⌘0) and a consolidated **AI** toolbar menu.
- **Internals.** All LLM calls funnel through one dispatch + JSON-parse +
  provider-resolution + bulk-runner path (see CLAUDE.md → LLM operations).

## 0.5 — Library maintenance

- **Manage folders** (sheet + sidebar). Rename, merge, or remove folders
  library-wide. Surfaced from a `square.and.pencil` icon on the Folders
  sidebar header and a right-click menu on each folder entry.
- **Consolidate authors** via LLM. Mirror of Consolidate Tags. Finds
  "J. Smith" / "John Smith" / "Smith, John" duplicates and proposes merges.
  Conservative — middle-initial differences and ambiguous cases stay separate.
- **Multi-pass consolidation.** Author consolidation runs up to three LLM
  passes, each seeing the simulated result of the previous, so duplicates
  that only surface after first-round cleanup still get caught.
- **"et al." junk stripped** from author entries at three points: PDFKit
  metadata parse, LLM author extraction, sidebar display. The first
  Consolidate run on an existing library rewrites `metadata.json` to drop
  any literal `"et al"` entries that snuck in pre-0.5.2.
- **Sidebar owns operations, Settings owns configuration.** Earlier 0.5
  releases put management buttons in both places. 0.5.3 collapses to one:
  click the icon on a sidebar section header, or right-click an entry.

## 0.4 — LLM folders, authors filter, share, posters

- **LLM-assigned subject folders** in the sidebar. Each tagged paper gets
  a single subject folder ("Machine Learning", "Hydrology"). The LLM
  reuses your existing folder names rather than inventing new ones.
- **User folder override.** A picker in the detail pane lets you change
  the folder. The override (`user_folder`) is stored separately from the
  LLM's pick (`auto.folder`) so re-running the tagger never clobbers it.
- **Authors sidebar filter.** Every author across every byline position
  gets a row — click a name to filter the list to papers they appear on,
  not just first-author.
- **Posters** as a new kind alongside Paper / Book / Report.
- **Native Share** via the macOS share sheet — AirDrop, Mail, Messages,
  Notes — from the detail pane action row and from row right-click.
- **Double-click a paper in the list** to open it in Preview. The title
  cell shows a pointing-hand cursor on hover so the gesture is discoverable.
- **Re-extract** button in the detail pane forces a fresh LLM pass on a
  single paper, overriding the "current title looks fine" heuristic.
- **Tighter title heuristic.** `Microsoft Word - paper.pdf`, `Untitled1`,
  `LaTeX Source`, and similar PDFKit junk now trigger the LLM rescue path.
- **Collapsible Authors and Tags sections.** Click the section header to
  fold up long lists. Preference persists.

## 0.3 — Editable catalog

- Edit titles, kinds, and user tags inline.
- Star ratings rendered in the list, with a *Rated 4+* sidebar filter and
  *Rating (high → low)* sort.
- Cleaner detail pane: raw IDs hidden behind a disclosure.

## 0.2 — LLM auto-tagging

- Optional in-app auto-tagging via Claude CLI or local Ollama. Fills in
  topics, methods, application areas, summary, title, and authors when
  the heuristic flags the existing values as bad.

## 0.1 — First macOS app

- Native SwiftUI catalog over an iCloud-synced folder of PDFs and JSON.
  Add, search, tag, rate, read/saved flags, open in Preview, delete.
