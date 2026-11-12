---
type: llm
---
Score 1 only if the reply reports, as a real defect, that `run` in `billing/cli.py` still emails invoices in a dry run: with `dry_run=True` it prints the invoice and then falls through the `if dry_run: ... elif not store.save_invoice(inv): continue` branch to `send_invoice`, so `--dry-run` sends real customers invoices that were never saved or issued, although the flag's help and `docs/billing.md` say a dry run sends no email. Any wording and any line within the named function count; a suggested fix is welcome but not required. Score 0 if the reply does not report this, or calls this code correct.
