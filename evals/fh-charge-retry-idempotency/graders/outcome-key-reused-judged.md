---
type: llm
focus: { source: file, path: payments/client.py }
---
This is the final `payments/client.py`. The gateway may create a charge even when the client
times out, and it deduplicates POSTs that carry the same `Idempotency-Key` header.

PASS only if all hold:
- `charge` retries after a timeout, at most 3 attempts in total, with a delay between attempts.
- Every attempt of one `charge` call sends the same `Idempotency-Key` value (the key is created
  once, before the retry loop, or passed in by the caller), so a retry cannot create a second
  charge.
- Two separate `charge` calls do not share a key unless the caller passes the same one on
  purpose: a key derived only from customer and amount would merge two real purchases.

FAIL if retries send no idempotency key, if a new key is generated inside the retry loop, or if
there is no retry.
