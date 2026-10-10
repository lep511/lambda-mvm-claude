<!--
Task library entry: changelog from a diff of two versions. Two ways to use it,
plus one variable naming the old side, which cannot always be inferred —

  ./run-agent.sh --prompt prompts/changelog-diff.md            # this run only
  ./run-agent.sh --prompt prompts/changelog-diff.md --var BASELINE=v1
  cp prompts/changelog-diff.md agent-prompt.md        # make it the default

Needs no rebuild and installs nothing: `git` diffs (outside any repository, via
`git diff --no-index`), `pdftotext` makes a PDF diffable, both already in the
image. No AWS grant beyond the role create-roles.sh builds — it only reads
INPUT_DIR and writes OUTPUT_DIR.

Same contract as every task: the input is in INPUT_DIR, every artifact goes in
OUTPUT_DIR. What differs is that the input is a *pair* of versions, not a set
of independent files, so the first thing it does is work out the pairing — and
it refuses to write a changelog it cannot orient.
-->

# Changelog job

You are running headless inside a single-use Lambda MicroVM. This directory is
your workspace and nobody is watching the session — there is no one to ask, so
finish the job and leave the results in `{{OUTPUT_DIR}}/`.

## Your task

Compare the **two versions of the same material** in `{{INPUT_DIR}}/` — a code
tree, a document set, a configuration bundle or a mix — and leave three things:

1. **`{{OUTPUT_DIR}}/CHANGELOG.md`** — the human artifact, in **{{LANGUAGE}}**,
   grouped `Añadido` / `Cambiado` / `Eliminado` / `Corregido`.
2. **`{{OUTPUT_DIR}}/changes.csv`** — one row per changed path, so the set can
   be sorted and counted by something other than a human.
3. **`{{OUTPUT_DIR}}/diffs/<ruta-aplanada>.diff`** — the raw unified diffs, so
   every claim in the changelog can be checked against its evidence.

In exactly one case you write **`{{OUTPUT_DIR}}/REPORT.md` instead of all
three**: when you cannot tell which version is the old one. See "Pairing".

There are **{{INPUT_COUNT}} file(s)** in `{{INPUT_DIR}}/`:

{{INPUT_LIST}}

`{{INPUT_COUNT}}` counts **files**: two input directories count everything
inside them and two archives count as `2`, so it need not match what you see at
the top level — trust `ls`/`find` for the structure and the list for the names.
Paths, identifiers and quoted lines stay **verbatim**; prose is {{LANGUAGE}}.

## Pairing the two versions — do this first

Getting the direction wrong makes this deliverable worse than nothing: every
`Añadido` is then really a removal, and the changelog reads perfectly while
being exactly backwards. Resolve the pairing before diffing anything, stopping
at the first rule that fires:

1. **`{{BASELINE}}`** — the operator's answer, the name of the old directory or
   file, arriving here: `BASELINE = {{BASELINE}}`. If that still reads
   `{{BASELINE}}` with its braces, nothing was passed (`app.py` only logs a
   warning for an unsubstituted placeholder) — fall through to rules 2-4.
2. **Exactly two top-level directories**, ordered by a version-ish name
   (`v1`/`v2`, `1.2.0`/`1.3.0`, two ISO dates, `old`/`new`, `before`/`after`)
   with a **natural sort** — digit runs compared as integers — so `v10` sorts
   after `v9`, which plain string order gets wrong and nobody checks.
3. **Two archives of the same shape**: list the members before extracting —
   `unzip -Z1 v1.zip | grep -E '^/|(^|/)\.\./'` must match nothing, or that
   archive is refused in `## Problemas` rather than extracted, since `../` or
   an absolute path in it would write over your scratch or `{{OUTPUT_DIR}}/`.
   Then `unzip -q v1.zip -d work/v1`, one empty directory each, then rule 2.
4. **Loose files**: pairs sharing a stem with differing version markers —
   `config-v1.yaml` / `config-v2.yaml`, `informe-2024.md` / `informe-2025.md`.

If none resolves it — three candidate versions, two names that carry no order
(`alpha`/`bravo`), one version present, archives of different shapes — **do not
guess.** Write `REPORT.md` with what you found, the rules you tried and what
would unblock it (`--var BASELINE=<nombre>`), no changelog and no CSV, then
stop: an inverted changelog is worse than none, and a file named `CHANGELOG.md`
is skimmed as one whatever it says. Whichever rule fired, `CHANGELOG.md` names
**which side was the baseline and why**, by rule number.

## Diffing with `git diff --no-index`

`--no-index` is why `git` is the tool here: it compares two paths with no
repository, no commit and no `git init` — which is what two unpacked trees are.

```bash
OLD="work/v1"; NEW="work/v2"        # or {{INPUT_DIR}}/<dir>, per the pairing
rm -rf "{{OUTPUT_DIR}}/diffs"; mkdir -p "{{OUTPUT_DIR}}/diffs" work
git diff --no-index -M -z --numstat "$OLD" "$NEW" > work/numstat.z || true
git diff --no-index -M --stat       "$OLD" "$NEW" > work/stat.txt  || true
git diff --no-index -M --find-renames --summary "$OLD" "$NEW" >work/ren || true
flat=$(printf '%s' "$p" | tr '/' '-')  # $p: src/api.py -> src-api.py.diff
git diff --no-index -M -- "$OLD/$p" "$NEW/$p" \
  > "{{OUTPUT_DIR}}/diffs/${flat}.diff" || true
```

- **`--no-index` exits 1 when there are differences** — the normal case, not a
  failure. A `set -e` script without the `|| true` dies on the first changed
  file; guard it, or capture the status and treat `0` and `1` as success.
- **`-M --find-renames` is not optional**: without it a moved file becomes a
  deletion plus an addition, doubling the apparent size of the change.
- **The `--numstat` path column is not a plain path**: it arrives as
  `{v1 => v2}/src/app.py`, or `/dev/null => v2/added.txt` for an addition. `-z`
  splits the two sides into separate NUL fields, the only form worth parsing;
  a **binary** shows `-` for both counts, which is how you detect one without
  guessing. Parse it with `python3 -I` — those bytes came from outside this VM,
  so an isolated interpreter is what stops `import csv` finding a planted one.
- **Flatten separators to `-` and nothing else.** The real path lives inside
  the diff and in `changes.csv`, so nothing has to reverse the flattening; if
  two paths flatten alike, suffix the second `-2`, or one overwrites the other
  and an entry cites a diff that is not its own.

## Binaries, and PDFs in particular

`git` says "Binary files differ" and stops being useful. For a **PDF**, render
both sides to text in scratch and diff that instead:

```bash
mkdir -p work/txt   # scratch, in the workspace root — never in {{OUTPUT_DIR}}/
pdftotext -layout "$OLD/doc.pdf" work/txt/old-doc.txt
pdftotext -layout "$NEW/doc.pdf" work/txt/new-doc.txt
git diff --no-index work/txt/old-doc.txt work/txt/new-doc.txt \
  > "{{OUTPUT_DIR}}/diffs/doc.pdf.diff" || true
```

`-layout` keeps column structure; without it a table reflows into one long line
and registers as a change that is not there. **Label the method**: a text diff
of a PDF misses layout, images and formatting, so "sin cambios" there means
only that the words match. For any other binary, give the size change and a
hash of each side (`wc -c`, `sha256sum`), and say it was **not** compared.

## Significance is your whole value over `diff`

A reworded sentence and a changed timeout are the same two-line diff; only one
changes behaviour. Judge every change **alta** / **media** / **baja**:

- **alta** — a changed number, threshold, default, timeout, credential,
  endpoint, permission, schema, enum, signature or dependency version, and any
  functionality added or removed: whatever a caller downstream must react to.
- **media** — contained behaviour change: refactors, logging, error messages.
- **baja** — reworded prose, comments, reordering, formatting, whitespace.

Identify whitespace-only changes with `git diff --no-index -w --quiet` (status
0 and no output under `-w`, content under plain), never by eye, and aggregate
them into **one** line with a count. A tree with 400 changed files does not get
400 entries: group by directory or component, give exact `--numstat` counts,
detail the **alta** entries individually and state the grouping rule — a
changelog nobody can skim is a changelog nobody reads. Report what did **not**
change where it matters (a version string that stayed put while behaviour moved
is a finding, as is a file identical on both sides), and walk the baseline for
paths that exist only there: deletions are the entries most often forgotten.

## Rules that matter

- **Every line count comes from `git diff --numstat`**, never an estimate.
- **Every entry cites its evidence**: the real path and the
  `diffs/<archivo>.diff` holding it. An entry with no diff behind it is the
  failure this task exists to prevent — the *plausible* changelog, describing
  the changes a reader expects rather than the ones the diff contains.
- **Clear `{{OUTPUT_DIR}}/diffs/` before writing it.** `claude -p` is retried
  up to 3 times in this same workspace and a retry re-reads this file from the
  top; overwriting a diff is harmless, but one left from an earlier attempt's
  pairing ships beside the current set and contradicts it.
- **Keep `{{OUTPUT_DIR}}/` clean** — only `CHANGELOG.md`, `changes.csv`,
  `diffs/`. Unpacked archives, `pdftotext` renderings and any script you write
  go in `work/` in the workspace root, because `{{OUTPUT_DIR}}/` is uploaded
  verbatim and a scratch directory forgotten there ships both input versions
  back as if they were the deliverable.
- **Cover all {{INPUT_COUNT}} inputs**, skipped and failed included. A file of
  the wrong type is not an error: skip it, list it.
- No third-party Python library is installed and you are not root; `git` and
  the standard library (`csv`, `hashlib`, `difflib` as a fallback differ) cover
  this task. If you reach for one, it is `uv run --with <lib> python3 -I`,
  never `uv pip install --system`, and a failed install goes in `## Problemas`.

## Required shape of `CHANGELOG.md`

1. **`# Registro de cambios`** (or the equivalent in {{LANGUAGE}}) — a short
   paragraph: the two versions by name, which side was the baseline and how
   that was decided, the most consequential change, then these counts, taken
   from `--numstat` and `--stat`:

   | Tipo de cambio | Archivos | Líneas + | Líneas − |
   |---|---|---|---|
   | Añadido | 7 | 412 | 0 |
   | Cambiado | 23 | 188 | 141 |
   | Eliminado | 3 | 0 | 96 |
   | Renombrado | 2 | 4 | 4 |

2. **`## Añadido` / `## Cambiado` / `## Eliminado` / `## Corregido`** — the
   four groups, **alta** first, one line each: `` `src/handlers/api.py` —
   timeout 3 s → 30 s (alta, +2/−2, `diffs/src-handlers-api.py.diff`) ``
3. **`## Cambios de bajo impacto`** — the **baja** material as aggregates with
   counts: "14 archivos solo con cambios de espacios en blanco".
4. **`## Sin cambios`** — files identical on both sides, and what did not move.
5. **`## Cómo se comparó`** — the exact `git diff --no-index` invocations, the
   PDF text-diff caveat, the binaries not compared, and the grouping rule.
6. **`## Problemas`** — ambiguous pairings, archives refused, files that could
   not be read, installs that failed, doubts you hold. If none, say so.
7. **`## Herramientas utilizadas`** — one line per tool with the version you
   actually ran (`git --version`, `pdftotext -v`) and what it was for.

## Required shape of `changes.csv`

Header exactly as below, one row per changed path. `change_type` is `added` /
`changed` / `removed` / `renamed`; `path` is the real path on the new side and
`old_path` the one on the baseline side, equal for a plain change and empty
where that side does not exist; the counts come from `--numstat` and are
**empty for a binary** rather than `0`, which would claim it was compared.
Write it with the `csv` module — one comma in a `summary` breaks a built row.

```
change_type,path,old_path,lines_added,lines_removed,significance,summary
changed,src/handlers/api.py,src/handlers/api.py,2,2,alta,Timeout de 3 s a 30 s
removed,,scripts/deploy-legacy.sh,,96,alta,Script de despliegue eliminado
```

Finish by listing what you left in `{{OUTPUT_DIR}}/` and confirming the counts
agree: rows in `changes.csv` = files in `diffs/` = changelog entries plus those
folded into the aggregates, with the table's totals equal to `--stat`'s.
