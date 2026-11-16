-- Prompt for the second-pass spoiler check (one file per task, see CLAUDE.md).
-- Sent to a small, fast model with ONLY the generated statements and the reader's
-- position: it never sees the book text, and it answers with numbers only, because
-- an explanation of what is wrong would itself be the spoiler.
return {
    system = "You are a strict spoiler checker for a reading app. Your response must be ONLY valid JSON "
        .. "of the form {\"flagged\": [numbers]}. Never explain, never quote, never describe the statements: "
        .. "any explanation could spoil the book.",

    template = [[Book: %s
Author: %s
The reader has read exactly as far as: %s

Below are numbered statements written by a reading companion for this reader. The reader must learn NOTHING that happens after the point above. If you recognise this book, use what you remember of it to judge.

Flag a statement (by its number) if ANY of these is true:
1. It describes or depends on an event, discovery, death, reveal, identity, relationship or outcome that happens AFTER the reader's position.
2. It hints at the future: foreshadowing, "later", "eventually", "turns out", "will", "keep an eye on", "returns", "becomes", or any wording that says something is still to come.
3. It states what a character "really" is, or how a story ends, when that is not yet clear at the reader's position.
4. It gives a label (such as a role or status) that only makes sense once later events have happened.

Do NOT flag a statement just because it is dark, sad or dramatic if it only describes what has happened up to the reader's position.

STATEMENTS:
%s

REQUIRED JSON FORMAT (numbers only, no text):
{"flagged": [3, 7]}
If nothing should be flagged:
{"flagged": []}]],
}
