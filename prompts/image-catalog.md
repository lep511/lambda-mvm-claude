<!--
Task library entry: image cataloguing — metadata, a written description and
publishable alt text for every image in a batch. Two ways —

  ./run-agent.sh --prompt prompts/image-catalog.md    # this run only
  cp prompts/image-catalog.md agent-prompt.md         # make it the default

Needs no rebuild and nothing added to the image: Pillow is a Python library, so
it is named below and the agent installs it itself with uv — it ships aarch64
wheels, the only reason that resolves with no C toolchain here. Nor is there an
ImageMagick: no `convert`, no `identify`, Pillow instead.

Same contract as every task: the input is in INPUT_DIR, every artifact goes in
OUTPUT_DIR. What differs is where the evidence comes from — every description
is the agent's own reading of the pixels, with no OCR engine and no vision API
in the loop, so this one needs nothing beyond the execution role
create-roles.sh builds and makes no AWS call of its own.
-->

# Image cataloguing job

You are running headless inside a single-use Lambda MicroVM. This directory is
your workspace and nobody is watching the session — there is no one to ask, so
finish the job and leave the results in `{{OUTPUT_DIR}}/`.

## Your task

Catalogue every image in `{{INPUT_DIR}}/` and leave **three artifacts**:

1. **`{{OUTPUT_DIR}}/CATALOG.md`** — the report, written in **{{LANGUAGE}}**.
2. **`{{OUTPUT_DIR}}/catalog.csv`** — one row per file, exactly these columns:
   `filename`, `format`, `width`, `height`, `megapixels`, `bytes`, `mode`,
   `dpi`, `has_exif`, `has_gps`, `sha256`, `how_described`, `status`, with
   `width`/`height` the **stored** dimensions and `megapixels` their product.
3. **`{{OUTPUT_DIR}}/alt-text.json`** — a flat object, filename → alt text of
   **125 characters or fewer**, for whoever has to publish these images.

There are **{{INPUT_COUNT}} file(s)** in `{{INPUT_DIR}}/`:

{{INPUT_LIST}}

Images are `.jpg/.jpeg`, `.png`, `.gif`, `.bmp`, `.tif/.tiff` and `.webp`, plus
`.svg` — text, not pixels, so it is read as markup with the Read tool and never
looked at. Anything else is not an error: skip it and list it as uncatalogued.

Create two scratch directories in the workspace root: `work/` for scripts and
their output, `previews/` for the downscaled copies you look at. **Neither goes
inside `{{OUTPUT_DIR}}/`**, uploaded verbatim — a forgotten `previews/` there
ships megabytes of derivative PNGs as the deliverable. Nor the originals: the
operator has those already, as the input.

## Step 1 — the measurements, from a script

**No Python library is installed in this VM** and nothing in the standard
library opens a JPEG, so install **Pillow** with `uv` — `hashlib`, `json` and
`csv` you already have. Never `uv pip install --system`: you are not root.

```bash
mkdir -p work previews
cat > work/probe.py <<'PY'
import hashlib, json, os, sys, warnings
from PIL import Image, ImageOps, __version__ as pil_version
# A decompression bomb is a finding about this input, not a limit to raise.
warnings.simplefilter("error", Image.DecompressionBombWarning)
out = open("work/metadata.jsonl", "w", encoding="utf-8")
for path in sys.argv[1:]:
    row = {"filename": os.path.basename(path), "status": "ok",
           "bytes": os.path.getsize(path)}
    with open(path, "rb") as f:
        row["sha256"] = hashlib.file_digest(f, "sha256").hexdigest()
    try:
        with Image.open(path) as img:
            img.load()   # open() is lazy: this is what proves it is whole
            row.update(format=img.format, mode=img.mode, width=img.width,
                       height=img.height, dpi=img.info.get("dpi"),
                       display=list(ImageOps.exif_transpose(img).size))
            exif = img.getexif()
            sub, gps = exif.get_ifd(0x8769), exif.get_ifd(0x8825)
            row.update(has_exif=bool(exif), has_gps=bool(gps),
                       gps_tags=sorted(gps),  # which tags, never the values
                       orientation=exif.get(274), make=exif.get(271),
                       model=exif.get(272), software=exif.get(305),
                       taken=sub.get(36867), serial=sub.get(42033))
    except Exception as e:
        row["status"] = f"{type(e).__name__}: {e}"
    out.write(json.dumps(row, ensure_ascii=False) + "\n")
print("Pillow", pil_version)
PY
uv run --with pillow python -I work/probe.py "{{INPUT_DIR}}"/*
```

`-I` is there because those files came from outside this VM: an isolated
interpreter will not import a module from the working directory, so a `json.py`
that arrived with the input cannot be what `import json` finds. The `try` is
there because a malformed image is a classic parser-crash vector: a crash on
file 7 of 30 is a row in the catalogue, not the end of the job — and it is why
the glob can safely feed it every file, non-images included.

Two of those columns you could not get by looking. An EXIF **orientation** of
3, 6 or 8 means the stored width and height are *not* how the image displays,
so record both pairs or readers misjudge the shape. And `img.format` is the
content, not the suffix: a `.png` reporting `JPEG` breaks whatever trusts it.

## Step 2 — the description, from actually looking

You can read an image, and that is the point of this task: you are the vision
model here. But a 40-megapixel photo is thousands of tokens and no more legible
than a 1400 px long edge, so **downscale first** — the other reason for Pillow.

```bash
cat > work/preview.py <<'PY'
import os, sys
from PIL import Image, ImageOps
dst = "previews/" + os.path.splitext(os.path.basename(sys.argv[1]))[0] + ".png"
with Image.open(sys.argv[1]) as img:
    img = ImageOps.exif_transpose(img)   # see it as a viewer would
    if img.mode not in ("RGB", "L"):     # CMYK, P, I;16 and some RGBA render
        img = img.convert("RGB")         # as a blank image, and then you
                                         # would describe nothing at all
    img.thumbnail((1400, 1400))          # long edge, aspect preserved
    img.save(dst, "PNG")
PY
uv run --with pillow python -I work/preview.py "{{INPUT_DIR}}/terraza-01.jpg"
# -> previews/terraza-01.png     then Read that PNG and write what you see
```

`thumbnail` never upscales, so an image already under 1400 px comes back
unchanged — read that original directly, and say so in `how_described`. Work
**one image at a time**, writing its row and alt text before opening the next:
ten at once crowd out the descriptions you still owe, the same reason
`summary-docs.md` reads scanned pages one by one.

A description is factual and specific: subject, setting, composition, and any
text visible in the image **transcribed verbatim**. Colours only where they
carry meaning. What it must not be:

- **No invented names.** "Two adults at a café table" is a description; "Ana
  and Luis in Valencia" is fiction, unless the image itself says so.
- **No mood or quality as fact.** "Underexposed, subject in shadow" is an
  observation; "a joyful family moment" is a caption you made up.
- **Unreadable text is reported unreadable** — reading an image is still
  reading, and a guessed serial number is a fabricated fact.
- **If you cannot see it at all** (unsupported format, truncated file, an SVG
  read as markup) `status` says exactly that and the file gets **no**
  `alt-text.json` entry: an omission is a gap someone can fill, an invention is
  a lie that ships to a screen reader.
- **Alt text leads with the subject** — its first 125 characters are what the
  screen reader says out loud, and "a photograph of" is dead weight.

## Receipts, and the two machine-readable files

`claude` is retried up to three times on failure, **in this same workspace**,
and a retry re-reads this file from the top. Overwriting the catalogue is safe;
looking at 200 images again is expensive. So append a receipt per image as it
is done — `work/described.jsonl`, one JSON object per line with `filename`,
`how`, `status`, `alt` and `desc` — and skip any filename already in it.

Build `catalog.csv` and `alt-text.json` from that file joined to
`work/metadata.jsonl`, in one `python3 -I` script: `csv.DictWriter` for the
CSV, `json.dumps` for the JSON, **never** strings pasted into a template. These
filenames carry spaces, accents, commas and quotes, and one of them turns a
hand-built file into something no consumer can parse. Pass `ensure_ascii=False`
with `encoding="utf-8"` so accented text stays readable, and have the script
**refuse** alt text over 125 characters rather than cut it mid-word.

## Rules that matter

- **Never describe an image you did not look at.** `playa-sunset-2019.jpg` is a
  hypothesis, not a photograph — the failure this task exists to prevent.
- **Every number comes from the script.** Dimensions, bytes, mode, dpi, EXIF
  values and hashes come out of `work/metadata.jsonl`, not your impression.
- **Cover every file.** All {{INPUT_COUNT}} appear in `CATALOG.md` and in
  `catalog.csv`, including the ones you skipped and the ones that failed.
- Install failures, unreadable files and doubts go in the report: a confident
  description of an image you could not see is worse than a blank one.

## Required shape of `CATALOG.md`

1. **`# Catálogo de imágenes`** (or the equivalent heading in {{LANGUAGE}}) — a
   paragraph: how many images, which formats, total bytes, the top finding.

2. **Inventory table** — one row per input file:

   | Archivo | Formato | Dimensiones | Tamaño | Metadatos | Estado |
   |---|---|---|---|---|---|
   | terraza-01.jpg | JPEG | 4032x3024 (mostrada 3024x4032) | 2,1 MB | EXIF con GPS | Descrita (vista previa 1400 px) |
   | logo.svg | SVG | 512x512 (viewBox) | 4 KB | — | Leída como marcado, no como imagen |
   | captura.png | JPEG | 1920x1080 | 380 KB | Sin EXIF | Descrita (la extensión no coincide) |
   | recorte.tif | — | — | 12 MB | — | Truncada: no se pudo leer, sin alt |

3. **One `##` section per image**: its description and the verbatim
   transcription of any text in it. A single table is fine if there are many.

4. **`## Duplicados`** — `sha256` groups, which only the hash catches, and
   separately the near-duplicates you noticed by looking.

5. **`## Hallazgos de privacidad`** — files whose EXIF carries GPS coordinates,
   a camera serial or an owner name, each named with its tag but **never the
   values**: `{{OUTPUT_DIR}}/` is uploaded and shared, so repeating them moves
   the problem. Screenshots of text (documents in disguise) and oversized
   originals belong here too.

6. **`## Problemas`** — truncated files, bomb refusals, unsupported formats,
   unreadable images, mismatched extensions, failed installs. None? Say so.

7. **`## Contrato de alt-text.json`** — two entries, verbatim:

   ```json
   {
     "terraza-01.jpg": "Terraza con mesas de madera y toldo blanco; al fondo, el mar al atardecer.",
     "captura.png": "Formulario de alta con los campos nombre, correo y teléfono."
   }
   ```

8. **`## Herramientas utilizadas`** — one line per tool, the version you ran
   (`PIL.__version__`, `uv --version`, `python3 --version`) and what it did.

Finish by listing what you left in `{{OUTPUT_DIR}}/` and confirming the counts:
{{INPUT_COUNT}} input file(s) → N inventory rows → N rows in `catalog.csv` → M
entries in `alt-text.json`, and name the files behind any difference.
