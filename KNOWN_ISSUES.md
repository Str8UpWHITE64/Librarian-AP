# Known Issues — Librarian AP

## KI-1 · Intermittent invisible book when held (hidden mode) — **OPEN, shipped with diagnostics in 1.1.0**

### Symptom
In `book_visibility = "hidden"` mode, a received (unwarded) book occasionally renders
**invisible while held or looked at**, even though it is **visible in the shelf pile** and is
still **grabbable**. It can affect a single book, a few books in a series, or a whole series.
It is **rare and random** — different books each session, no reliable repro.

### Workaround (players)
The corruption is **per-session only**. To clear it:
- Return to the **title screen and Continue**, or
- **Relaunch** the game.

The affected books come back normal — nothing is lost, and the save is never corrupted.

### What we know (confirmed)
- **Hidden mode only.** Stacks mode never hides books, so it never exercises the machinery
  involved. (This is the only mode that actually hides books.)
- **Runtime-only.** Self-heals the instant the world reloads (title → Continue, or relaunch),
  because the book actors are re-spawned fresh. Nothing is written to the save.
- **Not an appearance bug.** The pile (HISM) copy renders fine; only the **actor's `SM_Book_1`
  mesh** is affected. A captured grab of an affected series read **100% healthy** on every field:
  `bHidden=false`, `meshHidden=false`, `meshVis=true`, `scaleX=1.0`, `opacity=nil`, mesh transform
  matching the actor (no deep-Z displacement), `CustomPrimitiveData` empty, and all material
  scalars/tints in normal range.
- **Survives `RefreshInfo`.** The proactive refresh sweep called `RefreshInfo()` on unwarded
  books **3,467 times** in one session and the book stayed broken — so the fault is **below** the
  BookInfo-derived appearance layer.

### Ruled out
Opacity (`Opacity` scalar nil/≥1), World-Position-Offset / `CustomPrimitiveData` displacement
(the `UpdateWPO` path is dead code; `cpd` was empty), mesh transform / actor Z, actor or mesh
scale, the `bHidden` / `bHiddenInGame` / `bVisible` flags, a null/wrong static mesh, material
tint corruption, and BookInfo (RefreshInfo doesn't fix it).

### Leading hypothesis
A **stale / detached render proxy** on the held actor's `SM_Book_1` component — the actor is
"visible" by every flag but is **not actually drawn**. This matches all evidence: invisible while
all flags read healthy, untouched by `RefreshInfo`, and cleared only by a full actor re-spawn
(reload). The not-yet-confirmed discriminator is `WasRecentlyRendered() == false` while the actor
is shown, plus the component's `bRenderInMainPass` / `IsVisible()` at that moment.

### Mitigations shipped in 1.1.0
- **Actor-state reconcile** (`reconcile_book_actors`, gated `BOOK_ACTOR_RECONCILE`): a periodic
  read-before-write pass that heals the *flag-based* variants — unwarded books left
  non-grabbable (collision off) or with stale mesh-hidden flags. It does **not** fix the
  render-proxy variant above (those flags read healthy), but it closes the simpler failure modes.

### Diagnostics shipped in 1.1.0 (how to capture an occurrence)
All gated, read-only, and silent unless something is wrong. If you hit the bug, **send
`…/Librarian/Binaries/Win64/UE4SS.log`** and grep for these markers:

| Log marker | Meaning |
|---|---|
| `[invis-scan] *** SUSPECT *** series=…` | The passive scanner found an unwarded book that's **shown but not drawn** across several scans, then dumped its full state on the following `[book-hook] SCAN…` lines. **The key capture — no manual repro needed.** |
| `[invis-scan] census: shown=… notDrawn=… newSuspects=…` | Per-sweep scale + self-calibration (how well `bHidden` tracks "near"). Silent when clean. |
| `[book-hook] *** BROKEN-GRAB ***` / `*** INVISIBLE-CONFIRMED ***` | Fired when **you grab** an affected book: full state dump, plus a deferred (≈0.6 s) re-check confirming the held actor was genuinely not drawn (`renderInMainPass` / `smIsVisible`). |

Toggle any of these off in `Scripts/diag_flags.lua` (`BOOK_INVIS_SCAN`, `BOOK_EVENT_HOOKS`)
if the logging is unwanted — none of them change gameplay.

### Next step toward a fix
Confirm the render-proxy hypothesis from a captured `SUSPECT` / `INVISIBLE-CONFIRMED` dump:
- If `renderInMainPass=false` → re-assert it in the reconcile (one line).
- If everything reads visible but `WasRecentlyRendered=false` → force a component re-register on
  the held actor (the lightweight equivalent of the re-spawn that already heals it), gated and
  A/B-tested, since this is crash-stabilized rendering code.
