-- Prompt for the chapter debrief (one file per task, see CLAUDE.md). One template; the
-- genre profile changes its FOCUS, the depth changes which sections are asked for.
-- Everything the debrief says must come from the chapter text and the chapter records
-- supplied here, so the usual spoiler rules apply in full.
return {
    template = [[Book: %s
Author: %s
Chapter: %s

You are writing a debrief for a reader who has JUST finished this chapter. They have read nothing after it.

FOCUS FOR THIS KIND OF BOOK: %s

SOURCES (use nothing else):
- RECORDS OF EARLIER CHAPTERS: compact notes on the chapters before this one.
- CHAPTER TEXT: the chapter itself.

ABSOLUTE RULES:
1. Say only what the CHAPTER TEXT and the RECORDS show. Do not use anything you remember about this book, its sequels or adaptations.
2. Never hint at what comes next. "Why it matters" says what the chapter SETS UP (a question, a tension, a promise), never how it plays out. Forbidden wording includes: "keep an eye on", "will later", "turns out", "eventually", "becomes", "returns", "is revealed".
3. In a mystery or thriller, never guess the solution, the culprit or the twist, even as a question.
4. Keep every statement short and plain. No spoilers about the rest of the book, of any kind.
5. Links to earlier chapters ("why it matters") must come from the RECORDS. If there are no records, skip the links.

%s
RECORDS OF EARLIER CHAPTERS:
%s

CHAPTER TEXT:
%s

REQUIRED JSON FORMAT (output ONLY a valid JSON object; leave out any field marked as not wanted):
{
  "in_brief": "3-4 sentences: what happened in this chapter and why it matters.",
%s  "record": {
    "summary": "About 60 words: what happened, as a record for later chapters.",
    "events": ["Up to 5 short events."],
    "character_changes": ["Up to 4 short notes on who changed and how, as of this chapter's end."],
    "threads": ["Up to 3 open questions this chapter raises, WITHOUT any outcome."]
  }
}]],

    -- the sections after "in_brief", depending on depth; %s of the template
    sections_full = [[  "what_happened": ["Short bullets of the events, in order. 4-8."],
  "who_changed": ["Character and relationship shifts in this chapter. 0-6."],
  "why_it_matters": "2-4 sentences: links to earlier chapters (from the RECORDS) and what this chapter sets up, not how it plays out.",
%s  "if_hard": {"passage": "The densest passage of the chapter, said in plain English.", "reread": "What is worth rereading, and why."},
  "questions": ["2-3 questions to sit with, moving from what happened to what it means."],
]],

    sections_quick = [[  "why_it_matters": "2-4 sentences: links to earlier chapters (from the RECORDS) and what this chapter sets up, not how it plays out.",
]],

    -- only when "reading between the lines" is on for this kind of book
    between_the_lines = [[  "between_the_lines": [
    {"claim": "One point about intent, symbolism or technique.", "tag": "in the text", "quote": "An exact quotation from the CHAPTER TEXT, 6-25 words, copied character for character."}
  ],
]],

    between_rules = [[READING BETWEEN THE LINES: give 2-4 claims. Every claim needs a short quotation copied EXACTLY from the CHAPTER TEXT so the reader can find it. Tag a claim "in the text" if the quote states it outright, or "interpretation" if it is your reading of it. A claim without an exact quotation will be thrown away.
]],

    no_records = "(none: this is the first chapter being debriefed)",
}
