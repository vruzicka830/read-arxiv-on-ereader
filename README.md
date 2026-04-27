# arXiv Browser for KOReader

Browse and download recent arXiv papers directly on your e-reader.

## What it does

Adds an **arXiv Browser** entry to KOReader's main menu. From there you can browse the most recent papers in a set of math categories, tap one to download it as a PDF, and open it immediately in KOReader.

Categories available:
- Operator Algebras (`math.OA`)
- Functional Analysis (`math.FA`)
- Spectral Theory (`math.SP`)
- Probability (`math.PR`)
- Statistics Theory (`math.ST`)

Downloaded papers are cached locally so they open instantly on subsequent visits. If a paper has already been downloaded, it opens from the cached copy.

## Installation

1. Copy the `arxiv.koplugin/` folder into your KOReader plugins directory.
2. Restart KOReader.
3. The plugin appears under **Menu → Tools → arXiv Browser**.

## Requirements

- KOReader with network access
- `ssl.https` (LuaSec) — bundled in standard KOReader builds
