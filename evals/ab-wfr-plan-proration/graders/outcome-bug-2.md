---
type: llm
---
Score 1 only if the reply reports, as a real defect, that `change_plan` in `billing/api.py` checks ownership with `require_owner(session, body.get("account_id"))`, against an account id the client sends, instead of the loaded subscription's `sub.account_id`. Any signed-in user can change another customer's plan (upgrade them with a charge, or schedule a downgrade) by sending their own `account_id` together with the victim's `subscription_id`. Any wording and any line within the named function count; a suggested fix is welcome but not required. Score 0 if the reply does not report this, or calls this code correct.
