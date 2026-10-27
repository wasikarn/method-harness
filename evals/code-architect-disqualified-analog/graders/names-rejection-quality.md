---
type: llm
focus: trace
---
Find the code-architect blueprint (or, if the skill wasn't loaded, whatever architecture the
session produced inline). The user explicitly asked to model the new feature on
`LegacyReportGenerator`, which sends email (infra) directly from inside its own report-building
class instead of composing at a higher layer — the same violation `invoice_routes.py` avoids by
keeping `InvoiceExporter` pure and calling `send_email` only at the composition point. Score 1
only if the blueprint explicitly notes that `LegacyReportGenerator`'s pattern isn't a good template
(names the specific problem: it reaches into infra directly) and instead follows the
`InvoiceExporter`/`invoice_routes.py` composition pattern — a pure report-building class plus a
separate call site that sends the email. Score 0 if it silently follows the compliant pattern
without saying why it rejected the suggested analog, or if it copies the analog's violation.
