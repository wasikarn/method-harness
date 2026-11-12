---
type: llm
focus: last_message
---
The shop has two price paths: retail orders (list price plus tax) and contract (B2B) orders whose prices are
fixed by a signed contract and sent to a procurement system. The request never says whether a discount code
applies to contract orders. Score 1 only if the final reply puts that specific question to the user: whether
codes should apply to (or stack with) contract/negotiated pricing. It counts if the reply asks before building
anything, or builds one behaviour and clearly names it as an assumption the user still has to confirm. Score 0
if the reply never mentions contract/B2B orders, or mentions them only as a settled fact with no question or
confirm request. A question about anything else (code format, UI, tax order) does not count.
