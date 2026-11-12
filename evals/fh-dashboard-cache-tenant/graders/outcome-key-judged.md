---
type: llm
focus: { source: file, path: app/dashboard.py }
---
This is the final `app/dashboard.py` of a multi-tenant app in which `User.id` is unique only
within `User.org_id` (two orgs can each have a user with id 1).

PASS only if both hold:
- `get_dashboard` returns a cached result for repeated calls for the same user within 60 seconds,
  using the shared cache (`from app.cache import cache` or equivalent).
- The cache key includes both the user's `org_id` and the user's `id` (directly in the key string
  or through a helper in this file that builds it from both), so two users with the same id in
  different orgs never share an entry.

FAIL if the key is built from `user.id` (or the user's name) without `org_id`, if nothing is
cached, or if the TTL is not 60 seconds.
