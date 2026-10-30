---
name: grilling
description: "Interview the human with ask_questions before acting. Interview mechanics and levels (NONE, LIGHT, MEDIUM, HEAVY). Roles reach it through `grill-me` or `grill-with-docs`; load it directly only when a decision is missing that only the human can make."
---

# Grilling

The interview primitive. It keeps no state and writes no files. `grill-me` and `grill-with-docs` are its two front doors; the role names the level.

Settle decisions with the human, one round at a time, until nothing about what or why is left to guess.

## Levels

The role names the level and what to probe; its numbers override this table. The card's question limit is a hard cap per round.

| Level | Budget |
|---|---|
| NONE | Ask nothing. List assumptions in the deliverable. |
| LIGHT | Usually nothing. At most one round of 2 questions, and only if input is missing or the reader is unclear. |
| MEDIUM | At most 2 rounds of 4 questions. |
| HEAVY | As many rounds as the tree needs, up to the card's limit per round. |

## Steps

1. **Facts first.** Read the card, earlier answers, the code, the docs, and whatever else the front door (`grill-me` or `grill-with-docs`) tells you to read. Anything you can look up is yours; never ask for it. Skip every question the card or history already answers.
2. **Draw the design tree.** Every decision branches into decisions that depend on it. The **frontier** is every decision whose prerequisites are settled.
3. **Ask the whole frontier in one `ask_questions` call**, within the level's budget, then end your turn. A question whose answer depends on another open question in the same round waits for a later round.
4. **Write each question to be answered fast.** One decision per question. The body says why it matters. `recommended` is your answer, worded so accepting it is a plain "yes". `options` are the real alternatives, up to 6, never a padded list.
5. **Reshape after answers.** Settled decisions move the frontier outward; an answer that contradicts an earlier one reopens that branch. Ask the next frontier.
6. **Done** when the frontier is empty or the budget is spent. Anything unresolved goes into the deliverable as an assumption or open question, so nothing is guessed silently.

## HEAVY close-out

When the tree is complete, ask one final question that plays back intent and scope in a few lines, with recommended answer "Yes, that is it". Submit the deliverable only after that confirmation.

## Probing a statement

- A solution is proposed: ask what need it serves. Keep the solution as a constraint, with the reason, if the human insists.
- A term conflicts with the glossary or with what the code does: say so at once and ask which is right.
- A boundary is fuzzy: test it with one concrete edge case.
- Two statements conflict: point it out and resolve it with them.
