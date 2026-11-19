# Rubric-anchoring evidence

`docs/METHODOLOGY.md` Rule 5, `agents/plan-reviewer.md`, and `skills/workflow/idea-audit/SKILL.md`
each require one worked example per rubric level, without a citation — `METHODOLOGY.md` has a
4096-byte pre-commit cap, so the doctrine line stays a short, uncited sentence and this file carries
the evidence the three call-sites point to.

## What the repo used to claim, and why it was wrong

All three files previously said: "an external benchmark found a subjective, example-free rule
scoring far worse than an anchored one on identical inputs." This traced to a real source —
`coldteadotai/abide`'s replay benchmark (via `CHANGELOG.md` v1.1.99 → auto-memory
`jev-typesafe-usecase-survey-2026-09-19.md`) — that does not support the claim as written: it
measured rule *scope and subjectivity* on **different** hunks per rule (not "identical inputs"),
its rules are binary yes/no (not the multi-level scored construct Rule 5 describes), and the
proposed fix ("a criteria example") was a stated-but-unrun idea, not a measured intervention. Full
provenance: `docs/research/decision-making-methods-2026-09-19.md` §2.

## What the evidence actually supports

**Human-rater reliability (the strongest direct support):** Jönsson & Svingby (2007), "The use of
scoring rubrics: Reliability, validity and educational consequences," *Educational Research Review*
2(2), 130-144 (DOI 10.1016/j.edurev.2007.05.002) — a review of 75 empirical studies — found rubric
reliability improves "especially if they are analytic, topic-specific, and complemented with
exemplars and/or rater training." Almost exactly Rule 5's own prescription. Caveat from the same
paper: "rubrics do not facilitate valid judgment of performance assessments per se" — this is a
reliability (agreement) finding, not a validity (correctness) one.

**The classical BARS lineage cuts the other way.** Landy & Farr (1980), "Performance rating,"
*Psychological Bulletin* 87(1), 72-107 — found rating *format* explains only a small fraction of
rating variance and called for a moratorium on the whole research program. Anchored rating scales
have a legitimate pedigree (Smith & Kendall 1963 coined the "one worked example per level"
technique), but fifty years of follow-up did not confirm the format itself does the work.

**LLM-judge evidence — the one controlled experiment that exists.** Zheng et al. (2023), "Judging
LLM-as-a-Judge with MT-Bench and Chatbot Arena," arXiv:2306.05685 (NeurIPS 2023), Appendix D.2:
adding few-shot examples to a judge prompt raised position-swap **consistency** substantially
(Claude-v1 23.8%→63.7%, GPT-4 65.0%→77.5%) — but the paper's own next sentence: few-shot GPT-4
"performs similarly to zero-shot" **on agreement with humans**. So anchoring buys reproducibility
(a decision you'd make again tomorrow), not established correctness.

**A 2026 paper found the opposite of the naive reading.** Roy et al., "PReMISE: Policy Rubrics as
Measurement Specifications for LLM Judges," arXiv:2605.30803 (Amazon AGI) — found **more
operationally specific rubrics were more exploitable**, because an anchored rubric tells a
motivated respondent exactly which surface features to produce. "High inter-rater agreement does
not imply low exploitability."

## The honest summary

Anchoring a rubric with worked examples is well-supported for human-rater *reliability*, thinly
supported and format-agnostic in its own classical (BARS) lineage, and — for LLM judges
specifically — raises self-consistency without established gains in correctness, and can even
increase how exploitable the rubric is. Rule 5's requirement stands on reliability/reproducibility
grounds, not on a "far worse without it" magnitude claim. Treat a Rule-5-scored verdict's
confidence accordingly: a band with a stated reason, never a bare self-reported number (see
`docs/reference/haiku-decision-calls.md` for the primitive, and
`docs/research/decision-making-methods-2026-09-19.md` §1.5 for the calibration literature it
cites — Xiong et al. 2023, Tian et al. 2023).

## References

1. Jönsson, A. & Svingby, G. (2007). "The use of scoring rubrics: Reliability, validity and
   educational consequences." *Educational Research Review* 2(2), 130-144.
   DOI 10.1016/j.edurev.2007.05.002
2. Landy, F. J. & Farr, J. L. (1980). "Performance rating." *Psychological Bulletin* 87(1), 72-107.
   DOI 10.1037/0033-2909.87.1.72
3. Smith, P. C. & Kendall, L. M. (1963). "Retranslation of expectations: An approach to the
   construction of unambiguous anchors for rating scales." *Journal of Applied Psychology* 47(2),
   149-155. DOI 10.1037/h0047060
4. Zheng, L. et al. (2023). "Judging LLM-as-a-Judge with MT-Bench and Chatbot Arena." NeurIPS 2023.
   arXiv:2306.05685 — Appendix D.2 (few-shot judge experiment).
5. Roy, S. et al. (2026). "PReMISE: Policy Rubrics as Measurement Specifications for LLM Judges."
   Amazon AGI. arXiv:2605.30803.
6. `coldteadotai/abide`, replay benchmark README (the repo's own prior, overstated citation) —
   full trace in `docs/research/decision-making-methods-2026-09-19.md` §2.

Related: [[METHODOLOGY]], [[haiku-decision-calls]]

Sources: [[decision-making-methods-2026-09-19]]
