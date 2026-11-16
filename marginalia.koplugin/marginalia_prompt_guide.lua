-- Prompt for the reading guide (one file per task, see CLAUDE.md).
-- The guide is the highest spoiler risk in the plugin: it leans on what the model
-- knows about the book, not on text the reader has read. So these are the strictest
-- instructions there are, and the result is checked again before it is shown.
return {
    template = [[Book: %s
Author: %s
Publisher's description / back cover: %s

%s
TASK: Write a short, SPOILER-FREE reading guide for someone who is about to start this book. Output ONLY a valid JSON object.

ABSOLUTE RULES (these matter more than being complete):
1. Reveal nothing about the plot beyond the very opening. No events, deaths, twists, secrets, relationships that develop, or endings, not even as hints. If something is a surprise in the book, it does not belong here.
2. "opening_characters" are ONLY people the reader meets in chapter 1 (or who the back cover itself names). Give each one a note of who they are at that first meeting, never what becomes of them. If you are unsure whether someone appears in chapter 1, leave them out. At most 6.
3. "themes" are QUESTIONS the reader can keep in mind, never answers or conclusions. 3 to 5 of them. A question must not give away how the book answers it.
4. "hard_parts" warns about what may make the book hard to read: unfamiliar names or naming conventions, references, long philosophical passages, an unreliable narrator, shifting point of view, dense period language. Practical advice only.
5. Do not compare this book's ending or outcome with anything. Do not say how the book ends, how characters end, or whether it is "tragic" or "hopeful" in the end.
6. Spell every name EXACTLY as it is spelled in the OPENING TEXT or the description when they are provided. Translations and editions spell names differently, and the reader will be matching your guide against the page in front of them. Use a spelling from your memory only when the name does not appear in what is provided.
7. If you do not know this book well (recent, obscure, or you are not sure), say so: set "knowledge" to "limited", and build the guide only from the description and the opening text provided. Do not invent anything.

"genre" must be exactly one of: literary, mystery_thriller, fantasy_scifi, romance, historical, horror, nonfiction, general. Pick the closest; use "general" if unsure. "genre_confidence" is "high", "medium" or "low".

REQUIRED JSON FORMAT:
{
  "genre": "literary",
  "genre_confidence": "high",
  "knowledge": "good",
  "author_and_period": "3-5 sentences: the author, when and where the book was written, and the historical and cultural context a reader needs.",
  "style_and_structure": "2-4 sentences: the literary movement, the style, how the book is built.",
  "opening_characters": [
    {"name": "Full name", "note": "One short sentence: who they are when first met."}
  ],
  "themes": ["A question to keep in mind?"],
  "hard_parts": ["One practical thing that may make the book hard."]
}]],

    -- placed in the "%s" slot above when chapter-1 text is allowed and available
    opening_block = [[OPENING TEXT (the first chapter, the only part of the book you may use):
%s
]],

    -- placed in that slot when no book text is available
    no_text_block = [[No part of the book's text is provided. Use only the description above and what you reliably know about the book.
]],
}
