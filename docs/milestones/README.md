# docs/milestones/ — AI-first milestone capture

**Audience: an AI assistant in a future session, not a human reader.** Each file
is a dense, self-contained record of one *completed* milestone: what was built,
why it was designed that way, the exact commands and problems along the way, and
how it was verified. The goal is that documentation, articles, or tutorials
about Zurvan can later be generated from these files alone — without re-mining
git history or re-reading the whole codebase, and within tight token budgets.

Zurvan is an educational project; the *process* (dead ends, root causes, order
of operations) is as much the payload as the result.

## File naming

```
v1-m<N>-<slug>.md        one per v1 milestone (v1 had 7 + the SSH addition)
v2-m<N>-<slug>.md        one per v2 milestone (6 planned; written as each completes)
```

## Schema

YAML frontmatter (machine-scannable index):

```yaml
id / version / milestone / title
status: done          # only done milestones get a file
completed: YYYY-MM-DD
commits: [hashes]     # the milestone's commits, oldest first
key_files: [paths]    # where the implementation lives NOW (may have evolved since)
verification: ...     # the test script(s) or manual check that proved done-when
```

Body sections, always in this order (omit only if truly empty):

1. **Goal** — one paragraph, what and why.
2. **Done-when** — the acceptance criterion, verbatim spirit of the roadmap.
3. **Design decisions** — each decision with its *why*; include rejected alternatives.
4. **How it was built** — ordered steps with real commands.
5. **Key files** — path → role table.
6. **Problems hit** — symptom → root cause → fix. The most valuable section.
7. **Verification** — what was run and what was observed.
8. **Deferred / rabbit holes avoided** — scope lines deliberately not crossed.

## Convention (from 2026-07-07 onward)

When a milestone's done-when passes, write its capture file **in the same
session**, before or with the closing commit. Session knowledge (thought
process, failed attempts, exact error strings) evaporates; commit messages
keep only the summary. This folder is where the rest survives.
