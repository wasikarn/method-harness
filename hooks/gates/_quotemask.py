#!/usr/bin/env python3
# Shared bash quote/comment masker, extracted 2026-09-20 (deferred finding #10
# follow-up) after subagent-git-guard.py's _mask_quotes and test-integrity.py's
# _mask_quotes_bash drifted into byte-identical copies that independently
# missed, then independently fixed, the same "#" comment bug -- the exact
# same-bug-twice pattern GH #154/#155 already hit once for agent_id truthiness.
#
# Import defensively, same posture as _journal.py: every caller does
# `try: from _quotemask import mask_quotes / except Exception: <inline copy>`,
# never a bare import -- irrecoverable.sh's wrapper turns any non-{0,2} exit
# into a hard deny, so an ImportError here must never become a machine-wide
# Bash lockout on a deny-tier gate.
#
# Parsing/masking only, never a verdict or fail-direction -- callers still own
# what regex/anchor runs against the masked string and their own fail
# direction, per operating-model.md's "each gate owns its error path" line.

# ")" added 2026-09-21 (deep-audit): "(true)#don't" is a comment from "#" on
# in real bash. "}" and a backtick are NOT metacharacters ("}#x" is one
# word), so they stay out on purpose.
_WORD_BOUNDARY_CHARS = set(" \t\n;&|()")


def mask_quotes(s):
    # Every char inside a quoted span (quotes included) becomes a placeholder
    # that matches neither a separator, a keyword, nor a flag; output length
    # equals input so match positions found against the masked string still
    # line up with the original. Single-quote spans are literal, double-quote
    # spans honor backslash escapes, as in bash. A "#" at a word boundary
    # (start of string, or right after whitespace/;/&/|/(/)/newline) opens a
    # bash comment that masks to end-of-line with no quote semantics inside
    # it -- the fix for the live bug both prior copies independently hit.
    #
    # ponytail: heuristic word-boundary check, not full tokenization (no
    # backtick/$()-aware nesting either) -- widen _WORD_BOUNDARY_CHARS if a
    # real miss traces to an omitted operator. A backslash-escaped quote
    # OUTSIDE a span is a literal (GH #157 sibling, 2026-09-21); other
    # escaped characters outside spans are left as-is. A backslash-newline
    # (odd run) is a line continuation (GH #286): the shell deletes the pair.
    # GH #306: when a blank, a separator or the end follows, nothing glues and
    # the pair is blanks in place (`git\<nl> stash` is `git stash`). When a
    # word char follows, the two halves are one word (`g\<nl>it` is `git`):
    # the two blanks go to the FRONT of that word, so the joined word reads
    # whole to the callers' anchors and every char after the pair keeps its
    # offset. A "#" after a mid-word pair stays mid-word, not a comment.
    # GH #820 item 5: a ")" that closes a "(" glued after "$", "<", ">" or
    # "=" ($(..) $((..) <(..) >(..) name=(..)) ends inside its word, so a "#"
    # right after it is no comment (`echo $(date)#|claude` pipes); a subshell
    # ")" or an unmatched one (a case pattern) still ends the word.
    # GH #833: a case read as a command pushes "c" until its esac, so a
    # pattern's ")" inside $(..) cannot pop the $( flag; an extglob group
    # @( !( ?( *( +( glues as $( does; a line continuation between "$" and
    # its "(" is stepped over (_back). Fail safe: a "c" pushed by mistake
    # (`echo do case`) or never closed leaves each ")" after it unsure, so
    # while one is on top a ")" keeps "#" in its word whenever a glued "("
    # is still open (ng); that only reads more, never less.
    def _back(k, blanks):
        # GH #833: the index of the char bash reads before s[k] (-1 at the start) and whether a backslash escapes it,
        # stepping over line continuations (an odd backslash run, then a newline) and, with blanks, unescaped blanks
        k -= 1
        while k >= 0:
            r = k - 1
            while r >= 0 and s[r] == "\\":
                r -= 1
            if s[k] == "\n" and (k - 1 - r) % 2 == 1:
                k -= 2
            elif blanks and s[k] in " \t" and (k - 1 - r) % 2 == 0:
                k -= 1
            else:
                return k, (k - 1 - r) % 2 == 1
        return k, False

    def _cmd_word(i, word, after, leads):
        # GH #833: whether s[i:] starts the reserved word `word` where bash reads it: at the start, after a char in
        # after, or after a word in leads; a blank, a separator or the end follows it
        if not s.startswith(word, i) or s[i + len(word):i + len(word) + 1] not in ("", " ", "\t", "\n", ";", "&", "|", ")"):
            return False
        k, e = _back(i, True)
        if k < 0 or not e and s[k] in after:
            return True
        for w in leads if not e else ():
            j = k + 1 - len(w)
            if j >= 0 and s.startswith(w, j) and (j == 0 or s[j - 1] in " \t\n;&|("):
                if w != "in":
                    return True
                m = _back(j, True)[0]  # `in` leads only as `case WORD in`, never as an argument (`echo in esac`)
                while m >= 0 and s[m] not in " \t\n":
                    m -= 1
                m = _back(m + 1, True)[0]
                return s.endswith("case", 0, m + 1) and (m < 4 or s[m - 4] in " \t\n;&|(")
        return False

    out = []
    pad = {}  # out index -> blanks to put in front of that piece (GH #306, #833)
    word_start = 0  # out index where the current word begins
    ng = 0  # GH #833: how many entries of parens are True
    ie = -1  # GH #833 review 3: end of the unsure line, where quotes and "<" are inert
    unsure = -2  # GH #833 review 2: index in s of the last ")" read while a case marker was on top
    parens = []  # GH #820 item 5: per open unquoted "(", whether it is glued
    i, n = 0, len(s)
    at_word_start = True
    while i < n:
        c = s[i]
        if c == "#" and unsure >= 0 and _back(i, False)[0] == unsure:
            # GH #833 review 2-4: as a comment the line hides nothing below it, and as a word a quote or "<<" in it
            # could; so it is read as a word, but up to its end (ie) no quote or comment opens and each "<" masks to
            # Q. Once such an inert quote or "<" shows up, the quote state past the line is unknown: ie moves to the end
            if i >= ie:
                ie = s.find("\n", i)
                ie = n if ie < 0 else ie
            out.append(c)
            i += 1
            at_word_start = False
            continue
        if c == "#" and at_word_start and i >= ie:
            while i < n and s[i] != "\n":
                out.append(" ")
                i += 1
            continue
        if c == "'" and i >= ie:
            out.append(" ")
            i += 1
            while i < n and s[i] != "'":
                out.append("Q")
                i += 1
            if i < n:
                out.append(" ")
                i += 1
            at_word_start = False
        elif c == "$":
            # GH #161: ANSI-C quoting $'...' -- a backslash escapes the next
            # char, so $'\'' is one complete string. Without this branch the
            # bare "'" opened a fake span that masked the rest of the line.
            # Only the LAST "$" of an odd-length run can open it: "$$" is the
            # PID and leaves a following quote plain ("$$$'x'" is "$$" then
            # "$'x'"). An escaped "\$" never reaches here (see the backslash
            # branch, which masks it).
            j = i
            while j < n and s[j] == "$":
                out.append("$")
                j += 1
            if (j - i) % 2 == 1 and i < j < ie and s[j] == "'":
                out.pop()  # GH #833 review 5: an inert $'..' drops its $ as bash does; the blank goes to the word front
                pad[word_start] = pad.get(word_start, 0) + 1
                i = j
                continue
            if (j - i) % 2 == 0 or j >= n or s[j] != "'" or j < ie:
                i = j
                at_word_start = False
                continue
            out[-1] = " "
            out.append(" ")
            i = j + 1
            while i < n and s[i] != "'":
                if s[i] == "\\" and i + 1 < n:
                    out.append("Q")
                    out.append("Q")
                    i += 2
                else:
                    out.append("Q")
                    i += 1
            if i < n:
                out.append(" ")
                i += 1
            at_word_start = False
        elif c == '"' and i >= ie:
            out.append(" ")
            i += 1
            while i < n and s[i] != '"':
                if s[i] == "\\" and i + 1 < n:
                    out.append("Q")
                    out.append("Q")
                    i += 2
                else:
                    out.append("Q")
                    i += 1
            if i < n:
                out.append(" ")
                i += 1
            at_word_start = False
        elif c == "\\":
            # GH #157 sibling: backslashes outside a span pair up, and an
            # ODD run escapes the character after it. Only an escaped quote
            # is masked (it is a literal in real bash, never a span opener);
            # every other escaped character is left as-is so a backslash-
            # escaped "git" anchor bypass stays visible to the callers' own
            # anchor regexes. An even run leaves a following quote live.
            j = i
            while j < n and s[j] == "\\":
                j += 1
            if (j - i) % 2 == 1 and j < n and s[j] == "\n":
                # GH #286/#306: an odd run before a newline is a line
                # continuation; the shell deletes the pair (see the header).
                if j - i > 1:
                    out.append("\\" * (j - i - 1))  # escaped backslashes: word chars
                    at_word_start = False
                i = j + 1
                if i < n and s[i] not in _WORD_BOUNDARY_CHARS and word_start < len(out):
                    pad[word_start] = pad.get(word_start, 0) + 2
                else:
                    out.append("  ")
                continue
            out.append("\\" * (j - i))
            if (j - i) % 2 == 1 and j < n and s[j] in "'\"$":
                out.append("Q")
                j += 1
            elif (j - i) % 2 == 1 and j < n and s[j] in _WORD_BOUNDARY_CHARS:
                out.append(s[j])  # an escaped blank or separator is part of its word: a "#" after it is no comment
                j += 1
            i = j
            at_word_start = False
        else:
            if c == "c" and at_word_start and _cmd_word(i, "case", ";&|()\n", ("then", "do", "else", "elif", "if", "while", "until", "{", "!", "time")):
                parens.append("c")  # GH #833: a case pattern's ")" closes nothing until its esac
            elif c == "e" and parens and parens[-1] == "c" and _cmd_word(i, "esac", ";&)\n", ("in", "}", "fi", "done", "esac")):
                parens.pop()
            if i < ie and c in "'\"":
                # GH #833 review 5: an inert quote mark is dropped as bash drops it, its blank put at the front of the
                # word, so a quoted name still reads whole ("git" stash, g''it stash); from here on nothing opens (ie = n)
                pad[word_start] = pad.get(word_start, 0) + 1
                ie = n
            elif i < ie and c == "<":
                out.append("Q")
                ie = n
            else:
                out.append(c)
            i += 1
            at_word_start = c in _WORD_BOUNDARY_CHARS
            if at_word_start:
                word_start = len(out)
            if c == "(":
                k, e = _back(i - 1, False)  # GH #833: extglob @( !( ?( *( +( glue as $( does
                parens.append(k >= 0 and not e and s[k] in "$<>=@!?*+")
                ng += parens[-1]
            elif c == ")" and parens and parens[-1] == "c":
                if ng:  # GH #833 fail safe: a pattern or the real closer; a "#" after it is read both ways
                    at_word_start, unsure = False, i - 1
            elif c == ")" and parens and parens.pop():
                ng -= 1
                at_word_start = False  # GH #820 item 5: $(..)# is one word
    return "".join(" " * pad.get(k, 0) + p for k, p in enumerate(out)) + " " * pad.get(len(out), 0)
