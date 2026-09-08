# vocab-mode

`vocab-mode` adds vocabulary awareness to existing Emacs buffers. It is not a
document reader itself.

> **Emacs displays the content. vocab-mode understands the vocabulary.**

It is a minor mode: whatever major mode is already showing your text keeps
running, and `vocab-mode` layers vocabulary annotations on top. Words you have
never marked are highlighted as unknown, words you are working on are
highlighted as learning, and words you know look completely ordinary. Your
vocabulary is stored in one SQLite database, per language, shared by every
buffer.

The buffer text is never modified. Annotations are overlays, so read-only
buffers work, and disabling the mode leaves the buffer exactly as it was.

## Requirements

Emacs 29.1 or later, built with SQLite support — `vocab-mode` uses the built-in
`sqlite-open` / `sqlite-execute` / `sqlite-select` API introduced in Emacs 29.1.
Check with:

```elisp
(sqlite-available-p)
```

Developed and tested on Emacs 30.1. Older Emacs versions have no SQLite API and
are not supported.

## Installation

With `use-package` on Emacs 30, or `package-vc-install` on 29:

```elisp
(use-package vocab-mode
  :vc (:url "https://github.com/spkerkela/vocab-mode" :rev :newest)
  :commands (vocab-mode))
```

`M-x package-vc-upgrade RET vocab-mode` pulls later changes.

Development installation, from a checkout:

```elisp
(add-to-list 'load-path "/path/to/vocab-mode")
(require 'vocab-mode)
```

## Usage

```text
Open some text.
M-x vocab-mode
Language: german
```

The mode line then reads `Vocab[german]`, so a buffer always says which
language it is being read in.

The language is asked once per buffer and stays with it, including across
disabling and re-enabling the mode. Any simple identifier works: `german`,
`spanish`, `french`, `finnish`. Vocabulary is language-specific, so German
`die` and French `die` are unrelated entries.

The prompt completes over the languages you already use — the set grows by
itself, and the default is the last one you entered, so `RET` keeps you in the
same language. Nothing is validated: type a language that is new and it is
accepted. Case is irrelevant throughout, in what you type and what completes, so
`English`, `english` and `ENGLISH` are one language, not three.

You can also set it ahead of time, for instance as a file-local variable:

```elisp
;; -*- vocab-language: "german" -*-
```

### Keybindings

None. `vocab-mode` is a minor mode for arbitrary buffers, so it claims no keys
of its own — anything it bound would shadow the major mode, and bare letters
would shadow self-insertion wherever the buffer is editable. Every command is
available through `M-x`; bind what suits you:

```elisp
(keymap-global-set "C-c v v" #'vocab-mode)      ; toggle from anywhere
(with-eval-after-load 'vocab-mode
  (keymap-set vocab-mode-map "C-c v n" #'vocab-next-unknown)
  (keymap-set vocab-mode-map "C-c v p" #'vocab-previous-unknown)
  (keymap-set vocab-mode-map "C-c v k" #'vocab-mark-known)
  (keymap-set vocab-mode-map "C-c v l" #'vocab-mark-learning)
  (keymap-set vocab-mode-map "C-c v u" #'vocab-mark-unknown)
  (keymap-set vocab-mode-map "C-c v s" #'vocab-show-word)
  (keymap-set vocab-mode-map "C-c v r" #'vocab-refresh-buffer))
```

A prefix like this works in editable buffers too, where bare letters cannot.

For the fast reading workflow, `vocab-mode-bind-reading-keys` installs the
single-key set in `vocab-mode-map`:

```text
n      next unknown
p      previous unknown
1-4    mark familiarity level
k      mark known
l      mark level 1
u      mark unknown
RET    show word status
```

```elisp
(with-eval-after-load 'vocab-mode
  (vocab-mode-bind-reading-keys))
```

Those bindings are live only while the buffer is read-only — which is where
single-key reading belongs, in `nov-mode`, `eww-mode` and other viewers. In an
editable buffer each key falls through to whatever it would otherwise run, so
typing is never shadowed. Pass your own keymap to bind them somewhere else.

### Commands

| Command                   | Description                                             |
|---------------------------|---------------------------------------------------------|
| `vocab-mode`              | Toggle the mode in the current buffer                   |
| `vocab-show-word`         | Echo the word at point and its state                    |
| `vocab-mark-known`        | Store the word at point as known                        |
| `vocab-mark-learning`     | Store the word at point as learning                     |
| `vocab-mark-unknown`      | Delete the word's stored row, returning it to unknown   |
| `vocab-next-unknown`      | Jump to the next unknown word, wrapping around          |
| `vocab-previous-unknown`  | Jump to the previous unknown word, wrapping around      |
| `vocab-mark-level`        | Mark the word or phrase with familiarity level 1-4      |
| `vocab-translate-word`    | Show a translation of the word or phrase at point       |
| `vocab-forget-translation`| Delete the stored translation of the word at point      |
| `vocab-refresh-word`      | Refresh every occurrence of one word                    |
| `vocab-refresh-buffer`    | Rescan the buffer and re-read states from the database  |
| `vocab-clear-annotations` | Remove every annotation owned by `vocab-mode`           |

Marking a word updates every occurrence of it in the current buffer
immediately: `Hund`, `HUND` and `hund` all normalize to `hund`, so marking one
of them marks all of them.

Other buffers pick up changes the next time they are enabled, re-enabled, or
refreshed with `vocab-refresh-buffer`.

## Translation

`vocab-mode` ships no dictionary and depends on no LLM, but it has a socket for
one. Set `vocab-translate-function` and `M-x vocab-translate-word` starts
working; leave it nil and the command simply says so.

The function is called with the surface word, the buffer's language, and a
callback, and must call the callback with a string, or nil when it has nothing.
It may answer immediately or much later, so a dictionary process, a web lookup
or an LLM all fit without freezing Emacs:

```elisp
(defun my-vocab-translate (word language callback)
  (funcall callback (my-lookup word language)))

(setq vocab-translate-function #'my-vocab-translate)
```

An asynchronous backend, here [gptel](https://github.com/karthink/gptel):

```elisp
(defun my-vocab-translate-with-gptel (word language callback)
  (gptel-request word
    :system (format "Translate this %s word into English. Give the dictionary \
form and the meaning in at most 20 words. No preamble." language)
    :callback (lambda (response _info)
                (funcall callback (and (stringp response) response)))))

(setq vocab-translate-function #'my-vocab-translate-with-gptel)
```

Answers are stored in the database, keyed by language and normalized word, so a
word is translated once and stays translated across sessions and machines. An
in-memory cache sits in front, so a repeated lookup costs not even a query. A
prefix argument (`C-u`) asks the backend again and replaces what is stored;
`vocab-forget-translation` deletes one; `vocab-clear-translation-cache` drops
only the in-memory copies.

Translations survive marking a word known, or unknown again: what a word means
does not depend on whether you know it. Phrases are translated the same way.

Short answers appear in the echo area, longer ones in a `*vocab-translation*`
buffer.

## Vocabulary states

Between unknown and known there are four familiarity levels, so a word can move
towards known instead of jumping there.

| State     | Stored?                   | Appearance            |
|-----------|---------------------------|-----------------------|
| `unknown` | no — absence is the state | `vocab-unknown-face`  |
| level 1   | yes                       | `vocab-level-1-face`  |
| level 2   | yes                       | `vocab-level-2-face`  |
| level 3   | yes                       | `vocab-level-3-face`  |
| level 4   | yes                       | `vocab-level-4-face`  |
| `known`   | yes                       | unchanged             |

Unknown words are underlined; the levels are shaded backgrounds that grow
fainter as the word approaches known, which needs no marking at all. Mark a
level with `vocab-mark-level` or the digit keys, in either direction — a word
can drop back down as easily as it climbs.

A database written before levels existed keeps working: its `learning` entries
read as level 1, and the rows themselves are left untouched.

Scanning never writes to the database. Reading a document with 2,000 unknown
words creates zero rows; only your explicit marks are stored.

## Phrases

Anything you can select can be marked, so vocabulary is not limited to single
words. Select `как дела` and press a level, and the phrase becomes an entry of
its own, found and highlighted wherever it appears afterwards — including
across a line break, since text wraps where it likes.

Phrases are drawn above the words they cover and the words underneath keep
their own states, so a phrase you are learning can be made of words you already
know, or the reverse. With point inside a phrase, the commands act on the
phrase rather than the single word, since the phrase is what is highlighted.

They need no table of their own: a phrase is an entry whose text has a space in
it, matched case-insensitively like everything else.

## Customization

`M-x customize-group RET vocab RET`, or:

```elisp
(setq vocab-database-file "~/.emacs.d/vocab/vocab.sqlite")   ; the default
```

The database and its parent directory are created when first needed, and an
existing database is never dropped or recreated.

`vocab-unknown-face` sets a wavy underline and the four `vocab-level-N-face`
faces set progressively fainter backgrounds, so the underlying major mode's
colours keep showing through in every case. All are defined separately for
light and dark backgrounds.

## Compatibility

`vocab-mode` aims to work on top of any major mode that displays readable text:
`text-mode`, `markdown-mode`, `org-mode`, `nov-mode`, `eww-mode` and others.

`nov-mode` and `eww-mode` replace the whole buffer every time they render
another chapter or page, which throws the annotations away with it. Both are
listed in `vocab-render-hooks`, so `vocab-mode` rebuilds from their after-render
hook: turn the page and the new text is annotated, with vocabulary re-read from
the database so a word you marked in chapter one is already known in chapter
two. Add other rendering modes to that alist the same way.

Compatibility with complex major modes may otherwise vary in v0.1; a mode that
regenerates its buffer without such a hook needs `vocab-refresh-buffer`.

Narrowing is respected: only the accessible portion of the buffer is scanned and
navigated, and the mode never widens behind your back.

## Word detection and normalization

Words are runs of letters (`[[:alpha:]]`), so Unicode text works and punctuation
is never included: in `"Hallo, Welt!"`, point on either word gives `Hallo` or
`Welt`. Normalization is `downcase` only — no stemming, lemmatization, or
morphological analysis in v0.1. Both live behind `vocab-word-at-point` and
`vocab-normalize-word` so that language-specific behaviour can be added later.

## Tests

```sh
emacs -Q --batch -L . -L test \
  -l ert -l test/vocab-db-test.el -l test/vocab-mode-test.el \
  -f ert-run-tests-batch-and-exit
```

The suite uses temporary databases and never touches your real vocabulary file.

## Out of scope in v0.1

No document importing, dictionary or LLM backend of its own, EPUB/PDF parsing,
audio, flashcards or spaced repetition, lemmatization, encounter statistics, or
synchronization.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
