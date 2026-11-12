---
type: regex
target: { source: file, path: app/dashboard.py }
pattern: '\borg_id\b'
---
User ids are unique only inside an organisation (`app/models.py`, `docs/data-model.md`: the
first user of every org has id 1). A cache key built from `user.id` alone hands org 2's user 1 the
cached dashboard of org 1's user 1: another firm's name, invoice totals and activity. The
scaffold's `app/dashboard.py` never mentions `org_id`; the cache keys are strings
(`TTLCache` rejects tuples and objects), so a key that separates tenants has to name `org_id` in
this file. Fails on a key of `user.id` (or the name) alone. `check.py` beside this case is the
executable form: two orgs, same user id, different dashboards, and a second call inside 60 s does
not recompute.
Known false negative: a correct key built by a helper in another module (say
`cache.user_key(user)`) leaves `org_id` out of this file and fails here; `check.py` passes it.
