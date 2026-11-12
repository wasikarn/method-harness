---
type: llm
---
Score 1 only if the reply reports, as a real defect, that `build_export` in `accounts/export.py` puts `dict(user)` from `SELECT * FROM users` into the export, so the export file contains the user's `password_hash` (plus internal fields), contrary to docs/privacy.md ("It never holds your password hash or any token"); anyone who gets the file (a shared download, or another user through the download route) can attack the password offline. Any wording counts as long as it says the password hash ends up in the export. Score 0 if the reply does not mention this.
