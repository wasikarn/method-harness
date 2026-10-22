# Phase 4 — Interactive deepen, supported follow-ups

Full follow-up patterns for `SKILL.md`'s "Phase 4: follow-up (opt-in)"
section, kept out of the main file since Phase 4 only fires on a user
follow-up after the initial run, not on every invocation.

1. **"Deepen #2"** or **"Tell me more about the second shortlist idea"**
   → Re-run Phase 3 (Deepen) on just that idea, with the same sibling
   recombination pool, and return a fresh sketch + risk + first step.
2. **"Re-run with frames X, Y, Z"** → Replace the rotated/default frame
   set with the user's explicit picks and run Phase 1 → Phase 2 (and Phase 3 on the host path) again.
   Still cap at 5 frames and 2 waves.
3. **"Combine A and B"** (where A and B are idea texts or numbers from
   the wide set) → Spawn one Agent call under the `remove-assumption`
   frame to force a hybrid, then one deepen Agent call on the result.
