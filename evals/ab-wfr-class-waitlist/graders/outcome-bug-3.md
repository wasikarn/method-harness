---
type: llm
---
Score 1 only if the reply reports, as a real defect, that `promoteFromWaitlist` in `src/waitlist.ts` only checks `seatsLeft(...) <= 0` before promoting the next party, not whether that party's `partySize` fits in the seats left (`seatsLeft` in `src/capacity.ts` counts seats, summing `partySize`). A party of 3 is promoted into 1 free seat and the class is overbooked beyond its capacity. Any wording and any line within the named function count; a suggested fix is welcome but not required. Score 0 if the reply does not report this, or calls this code correct.
