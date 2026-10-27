---
type: llm
focus: trace
---
Find the code-architect blueprint (or, if the skill wasn't loaded, whatever architecture the
session produced inline). Score 1 only if: it proposes a new `CsvExporter` class
that lives in the domain layer alongside `PdfExporter` (i.e. in or next to
`src/domain/exporters.py`), is pure (no file-writing, no import of `src.infra.file_writer`), and
reuses `write_to_disk` unchanged at the composition point (`export_routes.py`) rather than
proposing a new writer. It should cite `PdfExporter` as the pattern it's following. Score 0 if the
new exporter performs file I/O itself, imports infra directly, proposes a second writer function,
or the analog is never mentioned.
