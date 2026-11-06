---
type: llm
# Not sent to the judge: this replaces the wider llm criteria (GH #921). It judges structure only.
# Presence of the specifics is in grit-complete.md, and invented facts go unchecked because the
# one-word judge cannot judge them.
---
Score 1 only if the final rewrite contains no forced triad: three adjectives or abstract phrases stacked in a row for rhythm, such as "robust, scalable, and seamless". A plain list of three concrete facts is fine.
