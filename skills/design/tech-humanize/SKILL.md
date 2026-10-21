---
name: tech-humanize
description: "Humanize dev/tech writing (English/Thai) to sound natural, not AI-generated. Use when editing chat, standup/PR/commit, UI copy, or prose/ticket/spec/ADR. Don't use for translation or STE."
model_limitation: "lexical-tell catalog currency: the enumerated tells shift across model generations. Re-validated 2026-09-07 against Wikipedia's Signs of AI writing. Next check at the quarterly cadence pass, docs/plans/mh-rebuild-v1-2026-09-05.md"
metadata:
  origin: kbg-native
model: inherit
effort: high
---

# Tech-Humanize: Remove AI Writing Patterns from Dev/Tech Writing (EN + TH)

You edit dev/tech writing, monolingual English, monolingual Thai, or Thai-English code-switching (Thai particles next to English tech terms), so it reads human. Built on Wikipedia's "Signs of AI writing" (WikiProject AI Cleanup) plus Thai-specific register, terminology, and anti-fabrication rules.

Two constraints hold through every step:

- **Anti-fabrication.** A fact you cannot verify right now is dropped (default Tier 1 DROP, `patterns-thai.md` §32.1). Grit comes from the source, never from invention.
- **Prose only.** When the input is a file, code blocks, commands, data, frontmatter, and quoted material stay byte-identical; only the prose around them changes.

## The loop

1. **Register and language gate.** Pick genre and language from §0 before scanning. Skipping this is the first cause of AI-sounding output.
   Done when: genre letter and language are named.
2. **Grit plan.** Decide what concrete specifics and point of view the rewrite will carry (Grit Gate below).
   Done when: at least one specific pulled from the source is listed, or the source is declared hollow.
3. **Identify every tell.** Scan against `cue-sheet.md` (§1-§30); for any Thai, load `patterns-thai.md` (§31-§42) first, since universal tells miss terminology drift and calque, a Thai-only class.
   Done when: every tell present is named, not the first loud few. Failure mode: stopping after the em dash and "delve" and missing the cluster a full pass shows.
4. **Draft rewrite.** Replace each named tell with the natural alternative; keep paragraph count and core meaning; natural aloud, varied length, simple constructions (is/are/has, คือ/เป็น), correct register, grit applied. Match the user's voice when they gave a sample (Voice below).
   Done when: every tell from step 3 is addressed and everything step 3 cleared is left as written. A cleared term that now looks wrong is new information: name it, then change it. Failure modes: deleting AI-isms without adding grit lands in the clean-but-neutral middle, which a skeptical reader still scores about 30/100 AI; an unnamed mid-rewrite change escapes steps 5 and 6.
5. **Ask "what still makes this read AI?"** and answer in a few bullets, checking the draft against the cue sheet again.
   Done when: each remaining tell is named, or the draft is declared clean.
6. **Final rewrite.** Resolve each step-5 bullet: name the fix, or write "kept as tradeoff: <reason>" (formal vocabulary the genre requires, for instance). Scan the delivered text for the literal `—` character (cue #14): claiming the dashes are cut is not the same as counting zero. Re-read aloud; vary sentence length; confirm the step-2 grit actually landed in the text.
   Done when: every bullet has a named resolution, the `—` count is zero (unless the user's own English writing sample uses em dashes on purpose, §14; never in Thai), and the step-2 specifics are present.

Deliver: the named tells, the draft, the still-AI bullets, the final rewrite, and optionally a short change summary. When the input is a file and the user asked to edit or humanize it, write the final back into that file as well.

## §0. Register and language gate

Pick genre **and** language; they are orthogonal. Match what the reader actually reads.

| # | Genre | Example | English ~% | Particle default | Apply |
|---|-------|---------|-----------|------------------|-------|
| **A** | Chat / LINE | chat, comment | 10–25% (TH) / 100% (EN) | 555 / ค่ะ / ครับ by gender / none (EN) | §34, §38 |
| **B** | Standup / PR / commit | daily standup, PR desc | 40–60% (TH) / 100% (EN) | no particle on terse items / none (EN) | §35, §38 |
| **C** | UI / error / notification | payment decline, 404 | 20–35% (TH) / 0% (EN) | one ค่ะ/ครับ opener / none (EN) | §36, §36.1, §38 |
| **D** | Prose / blog / strategy / ADR | article, brief | 30–50% (TH) / 100% (EN) | no bare particle / none (EN) | §37, §38 |

High cognitive load (hotfix, incident, alert) is written monolingual. An EN-only audience gets monolingual EN. Detail: §34–§38 in `patterns-thai.md`.

**Terminology:** keep English by default in internal dev writing (commit, merge, PR, staging, develop, production); user-facing text translates or transliterates per RTGS; Thai is never romanized internally. Decision tree: §31 in `patterns-thai.md`.

**Typography:** Thai has no inter-word spaces (a space is a phrase or sentence break); one space around English when it helps, glued to identifiers and numbers is fine (`PR #82`, `v1.11.37`); Arabic numerals (`2026`, `77%`), never Thai numerals.

**Calques to replace:** `ถือไว้` → `ยังไม่ปล่อยขึ้น prod / พักไว้`; `ดัน` → `merge / นำขึ้น prod`; `ระบบล้ม` → `ระบบล่ม / down` (§31 has worked before/after). An unverified completion claim (`ทดสอบบน staging ผ่าน`) is a fabrication-boundary case, not a calque: §32.

## The Grit Gate

**Removing the 30 patterns gets you to "clean," not "human."** Clean-but-neutral text sits in the safe middle, itself an AI tell. To clear it, every rewrite also does both:

1. **Surface the grit.** Pull the concrete specifics a real author includes and an LLM rounds off: ticket and PR refs, file and module names, the actual cause (race condition, double-submit, null from an API), real numbers, the one weird detail. Grit is what reads human, not the absence of fluff.
2. **Commit to a point of view.** Say which part matters and what you would actually do; balanced neutral reporting is the AI default. POV only where the genre allows it: blog, standup, ADR yes; legal, spec, reference stays plain, and plain *is* the human voice there.

**Fabrication boundary.** Specifics come only from the source or context. A point of view is yours to add (a plan, a recommendation, which part matters), voiced as yours where the genre allows; a fact, number, cause, or result is not. On a thin source the boundary wins: less grit beats invented grit. Pure puffery with nothing to pull: say so or ask for specifics; a polished, confidently empty paragraph is still AI.

**One unverifiable claim inside an otherwise real draft** differs from a hollow source. Keep the claim, strip unbacked certainty intensifiers (`เรียบร้อยแล้ว`, "completely", "fully"), and ask what was checked where the genre allows (Tier 2 hedge, §32.1). The three tiers apply in any language: unverifiable → drop, heard but unconfirmed → hedge once, sourced → cite.

Worked "soulless vs alive" example, same facts as neutral report and as a real voice: `examples.md`, Grit Gate section.

## Voice

Given a writing sample, match **their** voice: length, formality, paragraph openers, punctuation, recurring phrases. Replace AI patterns with the sample's own habits. Short sentences stay short; `ของ`/`อัน` stays, with no upgrade to `องค์ประกอบ`/`ส่วนประกอบ`.

No sample: the Grit Gate default. Opinionated where the genre allows, varied rhythm (a short sentence, then a longer one that arrives somewhere), and some mess let in; asides and half-formed thoughts read human, perfect symmetry reads algorithmic.

## Pattern cue-sheet

Thirty universal tells, all languages, one line per cluster; the full table is `cue-sheet.md` (**read it before scanning**; scans without it miss the cues). Thai-only tells (§31–§42): `patterns-thai.md`.

- **Content (§1-6)**: significance puffery, notability name-drops, -ing pseudo-depth tails, promo language, weasel attribution and vague association ("linked to", "associated with"), "challenges and future" formula.
- **Language and grammar (§7-13)**: AI-vocab words, copula avoidance, negative parallelism, rule of three, elegant variation (historical: older models, weak on current ones), false ranges, passive and subjectless fragments.
- **Style (§14-19)**: em dashes (#14, zero unless the user's English sample uses them on purpose; never in Thai), bold overuse, inline-header lists, title-case headings, emojis, curly quotes.
- **Communication (§20-22)**: chat artifacts, cutoff disclaimers and gap-fill, sycophancy.
- **Filler and hedging (§23-30)**: filler phrases, excessive hedging, generic positive conclusion, hyphenated-pair overuse, authority tropes, signposting, fragmented headers and thematic breaks, diff-anchored writing.

## Clusters, not single tells

One em dash means nothing; em dashes plus rule-of-three plus *vibrant tapestry* plus a "Conclusion" section is a confession. Before gutting prose that might be human, read the false-positive list and the signs of human writing in `patterns-universal.md`, Detection Guidance.

## Bundled resources

Each says when to load it; one level deep; read fully.

- `cue-sheet.md`: the 30-row table (pattern / cue / fix). **Load when:** starting any scan.
- `patterns-universal.md`: full §1–§30 (problem plus worked before/after), detection guidance. **Load when:** a named tell resists a fix, or before deciding prose is AI vs human.
- `patterns-thai.md`: §31–§42 Thai-specific rules (terminology and calque, anti-fabrication tiers, connectives, register matrix, code-switching tells, AI-leaked closers). **Load when:** the draft has Thai. **Skip for monolingual English.**
- `examples.md`: worked examples A (TH chat), B (TH standup), C (TH UI), D (TH prose), E (EN UI), F (EN standup), G (EN prose), and the Grit Gate soulless-vs-alive pair. **Load when:** stuck, or to show the process.
- `references.md`: external sources (RTGS, Mozilla Thai Style Guide, W3C Thai Layout, PyThaiNLP, Conventional Commits Thai), Thai-tech glossary, calque and typography cheat sheet. **Load when:** verifying transliteration or citations.
