# vocab-mode --- Implementation Specification

## Summary

`vocab-mode` is an Emacs minor mode that adds persistent
vocabulary-learning annotations to arbitrary text-containing buffers.

It is not a document reader and does not import or own content. Emacs
and existing major modes are responsible for displaying content;
`vocab-mode` layers vocabulary awareness on top.

> **Emacs displays the content. vocab-mode understands the vocabulary.**

The v0.1 loop is deliberately small:

1.  Open something readable in Emacs.
2.  Enable `vocab-mode`.
3.  Select the target language.
4.  Unknown words are highlighted.
5.  Navigate between unknown words.
6.  Mark words as known or learning.
7.  Vocabulary state persists across buffers and Emacs sessions.

The mode must never modify the underlying text merely to provide
vocabulary functionality.

------------------------------------------------------------------------

## Goals

The user should be able to:

-   enable `vocab-mode` in an arbitrary text-containing buffer;
-   retain the buffer's existing major mode;
-   choose a target language for that buffer;
-   see unknown words highlighted;
-   see learning words highlighted differently;
-   leave known words unhighlighted by `vocab-mode`;
-   navigate between unknown words;
-   mark the word at point as known, learning, or unknown;
-   have every occurrence of a changed word update immediately in the
    current buffer;
-   disable `vocab-mode` without disturbing the buffer;
-   open another buffer and have previously learned vocabulary
    recognized;
-   use the mode in read-only buffers.

## Explicitly out of scope

Do not implement:

-   a custom document reader or document importing;
-   a translation, dictionary or LLM backend of its own: `vocab-mode`
    provides the socket, the user's configuration provides the backend,
    and the package depends on neither;
-   EPUB/PDF parsing or web fetching;
-   audio, TTS, or subtitles;
-   flashcards or spaced repetition;
-   stemming, lemmatization, or morphological analysis;
-   encounter counts or statistics;
-   accounts, cloud synchronization, streaks, or gamification.

Vocabulary lives in one database file; sharing it between machines is
copying that file, not a feature of the mode.

If another Emacs mode already displays content, `vocab-mode` should aim
to work on top of it rather than reimplementing that functionality.

------------------------------------------------------------------------

## Package structure

``` text
vocab-mode/
├── vocab-mode.el
├── vocab-db.el
├── test/
│   ├── vocab-mode-test.el
│   └── vocab-db-test.el
├── README.md
└── LICENSE
```

### `vocab-mode.el`

Responsible for:

-   minor-mode definition and lifecycle;
-   keymap;
-   word detection and normalization;
-   scanning and buffer-local cache;
-   highlighting/annotations;
-   navigation and interactive commands;
-   cleanup.

### `vocab-db.el`

Responsible for:

-   SQLite availability checks;
-   database initialization and schema;
-   vocabulary lookup;
-   status updates and deletion.

Do not add source files without a clear reason.

------------------------------------------------------------------------

## Minor mode

Implement `vocab-mode` with `define-minor-mode`, conceptually:

``` elisp
(define-minor-mode vocab-mode
  "Add persistent vocabulary-learning annotations to the current buffer."
  :lighter " Vocab"
  :keymap vocab-mode-map
  ...)
```

It must be a minor mode, not a major mode. Enabling it must not replace
the current major mode.

The lighter must name the buffer's target language, for example
`Vocab[german]`, and follow it if it changes.

It should conceptually work with buffers such as `text-mode`,
`markdown-mode`, `org-mode`, `nov-mode`, `eww-mode`, and other modes
exposing readable text. Perfect compatibility with every complex mode is
not required for v0.1.

------------------------------------------------------------------------

## Mode lifecycle

### Enabling

1.  Determine target language.
2.  Verify SQLite support.
3.  Initialize/open the vocabulary database.
4.  Initialize the buffer-local vocabulary cache.
5.  Scan the accessible portion of the buffer.
6.  Resolve vocabulary states.
7.  Apply annotations.

### Disabling

1.  Remove all annotations created by `vocab-mode`.
2.  Remove hooks installed by it.
3.  Clear temporary buffer-local state where appropriate.
4.  Leave buffer text untouched.
5.  Leave unrelated text properties, overlays, faces, and major-mode
    state untouched.

Re-enabling reconstructs state from the persistent database.

------------------------------------------------------------------------

## Non-destructive behavior

This is a hard requirement.

`vocab-mode` must not modify buffer text to provide vocabulary tracking.

Highlighting may use overlays, text properties, font-lock integration,
or another standard mechanism. Choose the approach that most safely
coexists with arbitrary major modes.

All `vocab-mode` annotations must be identifiable and removable without
removing unrelated annotations. Disabling the mode in an EWW or other
formatted buffer must not destroy the underlying formatting.

The textual contents before enabling and after disabling must be
identical unless the user independently edited the buffer.

------------------------------------------------------------------------

## Read-only buffers

`vocab-mode` must work in read-only buffers.

The following must work when `buffer-read-only` is non-nil:

-   `vocab-mark-known`
-   `vocab-mark-learning`
-   `vocab-mark-unknown`

These commands modify SQLite state and visual annotations, not buffer
text.

------------------------------------------------------------------------

## Target language

Provide a buffer-local variable:

``` elisp
vocab-language
```

When enabling the mode, if it has no value, prompt:

``` text
Language:
```

Accept simple identifiers such as `german`, `spanish`, `french`, or
`finnish`. Do not validate against a predefined list in v0.1.

Prompt with `completing-read`, so the standard completion machinery
applies. Offer the languages already in use, defaulting to the last one
entered, but accept anything typed. Matching is case-insensitive and
languages are stored downcased: `English` and `english` are one
language.

Vocabulary is language-specific. `("german", "die")` and
`("french", "die")` are unrelated entries.

The selected language should remain associated with the buffer for its
lifetime, including after disabling and re-enabling `vocab-mode`.

------------------------------------------------------------------------

## Vocabulary states

States are `unknown`, four familiarity levels, and `known`:

``` text
unknown
1  2  3  4
known
```

### Unknown

Absence from the database means `unknown`. Unknown words receive the
most prominent annotation. They do not require database rows.

### Levels

Explicitly marked by the user and stored persistently. Level 1 is a word
just met and level 4 one nearly known. Each level is visually distinct
and less prominent than the one below it, so highlighting fades out as a
word is learned. A word may move in either direction.

Statuses written by earlier versions must keep working and must not be
rewritten on disk: `learning` reads as level 1.

### Known

Explicitly marked by the user and stored persistently. Known words
receive no `vocab-mode`-specific highlighting.

## Entries and phrases

An entry is a single word or a multi-word phrase; a phrase is an entry
whose normalized text contains a space, so both share one table.

Marking acts on the active region when there is one, which is how
phrases are created. Phrases are matched case-insensitively and
tolerate the whitespace of a line break. They are annotated above the
words they cover, and those words keep their own independent states.
With point inside a phrase, commands act on the phrase.

------------------------------------------------------------------------

## Persistence

Use Emacs's built-in SQLite support.

Default database:

``` text
~/.emacs.d/vocab/vocab.sqlite
```

Expose:

``` elisp
vocab-database-file
```

as a customizable variable.

Create the parent directory and database automatically when necessary.
Never silently destroy or recreate an existing database because of an
error.

------------------------------------------------------------------------

## Database schema

``` sql
CREATE TABLE vocabulary (
    language TEXT NOT NULL,
    word TEXT NOT NULL,
    status TEXT NOT NULL,
    PRIMARY KEY (language, word)
);
```

``` sql
CREATE TABLE translations (
    language TEXT NOT NULL,
    word TEXT NOT NULL,
    translation TEXT NOT NULL,
    PRIMARY KEY (language, word)
);
```

Valid stored statuses:

``` text
1  2  3  4
known
```

Absence means `unknown`.

`vocab-mark-unknown` deletes the row instead of storing an explicit
`unknown` value.

Scanning must not populate the database with unknown words. Database
writes occur only from explicit user actions.

------------------------------------------------------------------------

## Word detection

Provide:

``` elisp
vocab-word-at-point
```

It returns the complete word containing point. Prefer Emacs syntax
facilities rather than ASCII-only string splitting.

Punctuation must not be included. For `"Hallo, Welt!"`, point on `Hallo`
returns `Hallo`, and point on `Welt` returns `Welt`.

Unicode words must work. Sophisticated language-specific tokenization is
not required in v0.1.

------------------------------------------------------------------------

## Normalization

Provide:

``` elisp
vocab-normalize-word
```

``` text
normalized-word = collapse-whitespace(downcase(surface-word))
```

Thus `Haus`, `haus`, and `HAUS` all map to `haus`, and a phrase maps to
one key however the text it was read from happened to wrap.

Do not perform stemming, lemmatization, or morphological analysis. Keep
normalization behind a dedicated function so language-specific behavior
can be introduced later.

------------------------------------------------------------------------

## Buffer-local cache

Maintain a buffer-local cache mapping normalized words to vocabulary
state.

Conceptually:

``` text
"der"     → known
"mann"    → known
"ging"    → unknown
"langsam" → learning
```

Do not perform one SQLite lookup per occurrence.

During an initial scan:

1.  identify words;
2.  normalize them;
3.  determine unique normalized vocabulary;
4.  resolve states from the database;
5.  populate the cache;
6.  annotate occurrences.

When state changes:

1.  update the database;
2.  update the cache;
3.  refresh every occurrence of that normalized word in the current
    buffer.

------------------------------------------------------------------------

## Scanning

Scan the accessible portion of the current buffer and respect narrowing;
do not widen behind the user's back.

Scanning a document containing 2,000 unknown words must not create 2,000
rows. Absence from the database is sufficient to represent unknown
vocabulary.

------------------------------------------------------------------------

## Faces

Define customizable faces:

``` elisp
vocab-unknown-face
vocab-level-1-face … vocab-level-4-face
```

Known words use their ordinary appearance.

Requirements:

-   unknown is visually prominent;
-   learning is distinct from unknown;
-   work reasonably with both light and dark themes;
-   prefer inheritance/conservative attributes;
-   coexist as safely as possible with underlying major-mode faces.

------------------------------------------------------------------------

## Keymap

Provide:

``` elisp
vocab-mode-map
```

It is empty by default. A minor mode for arbitrary buffers must not
claim keys: anything bound would shadow the major mode, and bare letters
would shadow self-insertion wherever the buffer is editable. Commands are
reached through `M-x` until the user binds them.

v0.1 still prioritizes a fast reading workflow, so provide an opt-in that
installs the single-key set:

``` text
RET    vocab-show-word
k      vocab-mark-known
l      vocab-mark-learning
u      vocab-mark-unknown
n      vocab-next-unknown
p      vocab-previous-unknown
```

These bindings must be active only while the buffer is read-only, so that
in an editable buffer each key falls through to what it would otherwise
run.

------------------------------------------------------------------------

## Commands

### `vocab-show-word`

Determine the word at point and display:

``` text
<surface word> — <status>
```

Examples:

``` text
langsam — unknown
langsam — learning
```

Use the minibuffer/message area. If point is not on a word, report:

``` text
No word at point
```

### `vocab-mark-known`

Normalize the word at point, persist `known`, update the cache, and
refresh every matching normalized occurrence in the current buffer.

For example, if `Hund`, `Hund`, and `HUND` all normalize to `hund`,
marking one known updates all of them.

### `vocab-mark-learning`

Same behavior, but persist `learning`.

### `vocab-mark-unknown`

Delete the word's database row, update the cache to `unknown`, and
refresh all occurrences.

### `vocab-next-unknown`

Move point to the beginning of the next unknown word.

-   skip known and learning words;
-   wrap to the beginning of the accessible buffer;
-   never loop forever.

If none exist, display:

``` text
No unknown words
```

### `vocab-previous-unknown`

Equivalent backward navigation:

-   skip known and learning;
-   wrap to the end of the accessible buffer;
-   never loop forever.

### `vocab-refresh-word`

Refresh every occurrence of one normalized word without changing text or
unrelated annotations.

### `vocab-refresh-buffer`

Rescan the accessible buffer and restore correct annotations:

1.  clear stale `vocab-mode` annotations;
2.  scan current text;
3.  rebuild/update cache;
4.  apply current vocabulary states.

Do not rescan the entire buffer after every keystroke.

### `vocab-clear-annotations`

Remove all annotations owned by `vocab-mode` and no others.

------------------------------------------------------------------------

## Suggested internal database API

Aim for roughly:

``` elisp
(vocab-db-open)
(vocab-db-get-status language word)
(vocab-db-set-status language word status)
(vocab-db-delete-word language word)
```

Exact signatures may differ if a more idiomatic design is better.

Persistence logic must remain separate from presentation logic.

------------------------------------------------------------------------

## Suggested mode API

Aim for roughly:

``` elisp
(vocab-word-at-point)
(vocab-normalize-word word)
(vocab-status word)
(vocab-refresh-word word)
(vocab-refresh-buffer)
(vocab-clear-annotations)
```

Again, prefer clear Emacs conventions over blindly preserving these
exact signatures.

------------------------------------------------------------------------

## Buffer changes

The mode should tolerate buffer changes after enabling.

v0.1 does not need sophisticated incremental parsing.
`vocab-refresh-buffer` must restore correct state after arbitrary
changes.

A lightweight change hook may be used if simple and safe, but avoid:

-   whole-buffer rescans after every character;
-   complex incremental parsing;
-   premature optimization.

------------------------------------------------------------------------

## Multiple buffers

Vocabulary is global per language, not per document.

If `Hund` is marked known in one German buffer, another German buffer
should recognize `hund` when scanned.

v0.1 does not need live cross-buffer synchronization. Other buffers may
see updates when enabled, re-enabled, or refreshed.

------------------------------------------------------------------------

## Error handling

### No word at point

Commands requiring a word report:

``` text
No word at point
```

rather than exposing a low-level error.

### SQLite unavailable

If Emacs lacks SQLite support, enabling `vocab-mode` must fail with a
clear explanation that SQLite support is required.

### Database errors

Database errors must never silently delete, truncate, replace, or
recreate user data. Surface an understandable error.

### Unusual buffers

Unsupported buffer types should fail gracefully. Never assume a buffer
is writable.

------------------------------------------------------------------------

## Customization

Create:

``` elisp
(defgroup vocab ...)
```

At minimum expose:

``` elisp
vocab-database-file
```

and the faces:

``` elisp
vocab-unknown-face
vocab-learning-face
```

Do not add unnecessary options in v0.1.

------------------------------------------------------------------------

## Tests

Use ERT.

Tests must never touch the user's real vocabulary database. Use
temporary SQLite databases and clean them up.

### Database tests

Test:

-   database creation;
-   schema initialization;
-   absent word resolves to unknown;
-   insert known;
-   insert learning;
-   retrieve status;
-   learning → known;
-   known → learning;
-   deletion returns a word to unknown;
-   language isolation.

### Normalization tests

Verify:

``` text
Haus → haus
HAUS → haus
haus → haus
```

Include at least one Unicode example.

### Word detection tests

Test words adjacent to commas, periods, quotation marks, parentheses,
and Unicode punctuation where practical. Include Unicode text.

### Minor-mode lifecycle tests

Given:

``` text
Der Hund sieht den Hund.
```

verify:

-   enabling `vocab-mode` does not change the major mode;
-   words are detected;
-   unknown words receive unknown annotation;
-   marking `Hund` known updates both occurrences;
-   the underlying buffer string is unchanged;
-   disabling removes `vocab-mode` annotations;
-   unrelated buffer properties remain untouched.

### Persistence test

Using one temporary database:

1.  mark `Hund` known in a German buffer;
2.  destroy the buffer;
3.  create another German buffer containing `Hund`;
4.  enable `vocab-mode`;
5.  verify `hund` is known.

### Read-only test

Create a read-only buffer, enable `vocab-mode`, and verify that
known/learning/unknown operations work while text remains unchanged.

### Navigation tests

Test:

-   forward navigation;
-   backward navigation;
-   skipping known;
-   skipping learning;
-   forward wraparound;
-   backward wraparound;
-   no unknown words.

### Language isolation test

Mark a word known under one language and verify the same spelling
remains unknown under another.

### Narrowing test

Narrow a buffer, enable/refresh `vocab-mode`, and verify operations
remain inside the accessible portion.

------------------------------------------------------------------------

## README requirements

The README should state clearly:

> `vocab-mode` adds vocabulary awareness to existing Emacs buffers. It
> is not a document reader itself.

Development installation:

``` elisp
(add-to-list 'load-path "/path/to/vocab-mode")
(require 'vocab-mode)
```

Usage:

``` text
Open some text.
M-x vocab-mode
Language: german
```

Keybindings:

``` text
n    next unknown
p    previous unknown
k    mark known
l    mark learning
u    mark unknown
RET  show word status
```

Mention that compatibility with complex major modes may vary in v0.1.

State the minimum supported Emacs version based on the SQLite API
actually used by the implementation. Do not claim compatibility with
untested versions.

------------------------------------------------------------------------

## Definition of done

v0.1 is complete when this workflow works:

1.  User opens an arbitrary text-containing buffer.
2.  Its existing major mode remains active.
3.  User runs `M-x vocab-mode`.
4.  User selects `german`.
5.  Unknown vocabulary becomes highlighted.
6.  `n` moves through unknown vocabulary.
7.  User presses `k` on a word.
8.  Every normalized occurrence immediately becomes known.
9.  Buffer text remains unchanged.
10. User disables `vocab-mode`.
11. All `vocab-mode` annotations disappear.
12. Original buffer formatting/state remains otherwise intact.
13. User opens another buffer.
14. User enables `vocab-mode` for German.
15. Previously known vocabulary remains known.
16. The complete ERT suite passes.

------------------------------------------------------------------------

## Future direction

Possible progression:

``` text
v0.1  arbitrary-buffer vocabulary tracking          done
v0.2  translation/definition UI                     done, backend pluggable
v0.3  richer familiarity levels                     done, four levels
v0.4  deeper nov-mode / eww integration             done, re-render hooks
v0.5  language-specific lemmatization               parked
v0.6  phrase tracking                               done
v0.7  review / SRS                                  dropped
v0.8  statistics                                    dropped
```

The architectural principle should remain:

> **Emacs displays the content. vocab-mode understands the vocabulary.**
