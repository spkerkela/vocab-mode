;;; vocab-mode.el --- Vocabulary annotations for any text buffer -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Simo-Pekka Kerkelä

;; Author: Simo-Pekka Kerkelä
;; Version: 0.1
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, convenience

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Emacs displays the content.  vocab-mode understands the vocabulary.
;;
;; `vocab-mode' is a minor mode that layers vocabulary-learning
;; annotations on top of whatever major mode is already displaying text:
;; `text-mode', `markdown-mode', `org-mode', `nov-mode', `eww-mode' and
;; friends.  It never imports, owns or modifies the text; annotations are
;; overlays, so read-only buffers work and disabling the mode leaves the
;; buffer exactly as it was found.
;;
;; Words are tracked per language in one SQLite database (see
;; `vocab-db.el').  Three states exist: unknown (the default, never
;; stored), learning and known.

;;; Code:

(require 'vocab-db)
(require 'seq)

;;;; Customization

(defface vocab-unknown-face
  '((((background light)) :underline (:color "#a40000" :style wave))
    (((background dark))  :underline (:color "#ff8f8f" :style wave))
    (t :underline t :inverse-video nil))
  "Face for words that are not in the vocabulary database.
Only underlining is used so that the underlying major-mode faces keep
showing through."
  :group 'vocab)

(defface vocab-level-1-face
  '((((background light)) :background "#ffe08a")
    (((background dark))  :background "#5c4708")
    (t :underline t))
  "Face for a word just met: familiarity level 1, the least known."
  :group 'vocab)

(defface vocab-level-2-face
  '((((background light)) :background "#ffecb5")
    (((background dark))  :background "#4a3a0c")
    (t :underline t))
  "Face for familiarity level 2."
  :group 'vocab)

(defface vocab-level-3-face
  '((((background light)) :background "#fff4d6")
    (((background dark))  :background "#3a2f10")
    (t :underline t))
  "Face for familiarity level 3."
  :group 'vocab)

(defface vocab-level-4-face
  '((((background light)) :background "#fffaec")
    (((background dark))  :background "#2c2513")
    (t :underline t))
  "Face for familiarity level 4: nearly known, barely marked."
  :group 'vocab)

(define-obsolete-face-alias 'vocab-learning-face 'vocab-level-1-face "0.2")

(defconst vocab-level-faces
  [vocab-level-1-face vocab-level-2-face vocab-level-3-face vocab-level-4-face]
  "Faces for familiarity levels 1 upwards, in order.
Unknown words are more prominent than any of them and known words carry
no face at all, so the highlighting fades out as a word is learned.")

(defcustom vocab-translate-function nil
  "Function that produces a translation or definition, or nil for none.

`vocab-translate-word' calls it with three arguments: the surface WORD
at point, the buffer's LANGUAGE, and a CALLBACK.  The function must call
CALLBACK with the translation as a string, or with nil when it has none.

CALLBACK may be called immediately or much later, so a dictionary
process, a web lookup or an LLM all fit without blocking Emacs:

  (defun my-vocab-translate (word language callback)
    (funcall callback (my-lookup word language)))

  (setq vocab-translate-function #\='my-vocab-translate)

`vocab-mode' deliberately ships no backend and depends on none."
  :type '(choice (const :tag "None" nil) function)
  :group 'vocab)

;;;; Variables

(defvar vocab-mode)                     ; defined by `define-minor-mode' below

(defvar-local vocab-language nil
  "Target language of this buffer, as a simple identifier string.
Set it directly, through a file-local variable, or answer the prompt
when enabling `vocab-mode'.  The value survives disabling and
re-enabling the mode.")
;;;###autoload
(put 'vocab-language 'safe-local-variable #'stringp)
(put 'vocab-language 'permanent-local t)

(defvar vocab-language-history nil
  "Minibuffer history of languages entered for `vocab-language'.")

(defvar vocab-word-regexp "[[:alpha:]]+"
  "Regexp matching one vocabulary word.
Letters are recognized through Emacs character classes, so Unicode text
works; punctuation is never part of a match.")

(defvar-local vocab--cache nil
  "Buffer-local hash mapping normalized words to their vocabulary state.
Values are the symbols `unknown', `learning' and `known'.  The cache
exists so that scanning does not perform one database lookup per word
occurrence.")

(defvar vocab-render-hooks
  '((nov-mode . nov-post-html-render-hook)
    (eww-mode . eww-after-render-hook))
  "Alist mapping a major mode to the hook it runs after rendering.
These modes replace the whole buffer when they render another chapter or
page, which throws away the annotations with it, so `vocab-mode' rebuilds
them from that hook.  Entries are matched with `derived-mode-p'.")

(defvar-local vocab--render-hook nil
  "The after-render hook of this buffer's major mode, when it has one.
Set from `vocab-render-hooks' while `vocab-mode' is enabled.")

(defvar vocab-mode-map (make-sparse-keymap)
  "Keymap for `vocab-mode'.

Empty by default.  `vocab-mode' is a minor mode for arbitrary buffers,
so it claims no keys of its own: anything it bound would shadow the
major mode, and bare letters would shadow self-insertion wherever the
buffer is editable.  Bind what you want, for example:

  (keymap-set vocab-mode-map \"C-c v n\" #\='vocab-next-unknown)

For the fast single-key reading workflow, see
`vocab-mode-bind-reading-keys'.")

(defconst vocab-reading-keys
  '(("RET" . vocab-show-word)
    ("k"   . vocab-mark-known)
    ("l"   . vocab-mark-learning)
    ("u"   . vocab-mark-unknown)
    ("n"   . vocab-next-unknown)
    ("p"   . vocab-previous-unknown)
    ("1"   . vocab-mark-level)
    ("2"   . vocab-mark-level)
    ("3"   . vocab-mark-level)
    ("4"   . vocab-mark-level))
  "Single-key reading bindings, as an alist of key description and command.
Installed on demand by `vocab-mode-bind-reading-keys'.")

(defun vocab--reading-key-filter (command)
  "Return COMMAND in a read-only buffer, and nil anywhere else."
  (and buffer-read-only command))

(defun vocab-mode-bind-reading-keys (&optional keymap)
  "Bind `vocab-reading-keys' in KEYMAP, by default `vocab-mode-map'.

The bindings are live only while the buffer is read-only, which is where
a single-key reading workflow belongs: in `nov-mode', `eww-mode' and
other viewers, n and p walk the unknown words while k, l and u mark the
word at point.  In an editable buffer each key falls through to whatever
it would otherwise run, so typing is never shadowed.

Call it once after loading `vocab-mode':

  (vocab-mode-bind-reading-keys)

Returns the keymap."
  (let ((map (or keymap vocab-mode-map)))
    (pcase-dolist (`(,key . ,command) vocab-reading-keys)
      (keymap-set map key
                  `(menu-item "" ,command :filter vocab--reading-key-filter)))
    map))

;;;; Words

(defun vocab--letter-at (pos)
  "Return non-nil when the character at POS is a letter."
  (and pos (>= pos (point-min)) (< pos (point-max))
       (let ((char (char-after pos)))
         (and char (string-match-p vocab-word-regexp (string char))))))

(defun vocab-bounds-of-word-at-point ()
  "Return the (BEG . END) bounds of the word at point, or nil.
Point counts as being on a word when it sits on one of its letters or
directly after its last letter.  Punctuation is never included."
  (let ((start (cond ((vocab--letter-at (point)) (point))
                     ((vocab--letter-at (1- (point))) (1- (point))))))
    (when start
      (save-excursion
        (goto-char start)
        (while (vocab--letter-at (1- (point)))
          (forward-char -1))
        (let ((beg (point)))
          (goto-char start)
          (while (vocab--letter-at (point))
            (forward-char 1))
          (cons beg (point)))))))

(defun vocab-word-at-point ()
  "Return the surface form of the word at point, or nil if there is none."
  (let ((bounds (vocab-bounds-of-word-at-point)))
    (when bounds
      (buffer-substring-no-properties (car bounds) (cdr bounds)))))

(defun vocab-normalize-word (word)
  "Return the normalized form of WORD used as the database key.
Normalization is `downcase' plus collapsing whitespace, so `Haus',
`haus' and `HAUS' all map to \"haus\", and a phrase picks up the same
key however the text happened to wrap.  No stemming or lemmatization
happens here, but keeping it in one function leaves room for
language-specific rules later."
  (when word
    (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (downcase word)))))

(defun vocab-phrase-p (thing)
  "Return non-nil when THING is a multi-word entry rather than one word."
  (and thing (string-match-p " " (vocab-normalize-word thing))))

(defun vocab--status-name (status)
  "Return a human-readable name for STATUS."
  (pcase status
    ('unknown "unknown")
    ('known "known")
    ((pred integerp) (format "level %d" status))
    (_ (format "%s" status))))

;;;; State

(defun vocab--ensure-enabled ()
  "Signal a user error unless `vocab-mode' is active in this buffer."
  (unless (and vocab-mode vocab--cache)
    (user-error "vocab-mode is not enabled in this buffer")))

(defun vocab--resolve (words)
  "Make sure every word in WORDS has an entry in `vocab--cache'.
WORDS must already be normalized.  Words missing from the cache are
looked up in a single batched query; those absent from the database are
cached as `unknown' without being written back."
  (let ((missing (seq-remove (lambda (word) (gethash word vocab--cache)) words)))
    (when missing
      (setq missing (delete-dups missing))
      (let ((stored (vocab-db-get-statuses vocab-language missing)))
        (dolist (word missing)
          (puthash word (or (gethash word stored) 'unknown) vocab--cache))))))

(defun vocab-status (word)
  "Return the vocabulary state of WORD: `unknown', `learning' or `known'.
Uses the buffer-local cache when `vocab-mode' is enabled, and falls back
to a direct database lookup otherwise."
  (let ((normalized (vocab-normalize-word word)))
    (cond
     ((null normalized) nil)
     (vocab--cache
      (vocab--resolve (list normalized))
      (gethash normalized vocab--cache 'unknown))
     (t (or (vocab-db-get-status vocab-language normalized) 'unknown)))))

;;;; Annotations

(defun vocab--face (status)
  "Return the face to use for STATUS, or nil when it needs none."
  (pcase status
    ('unknown 'vocab-unknown-face)
    ('known nil)
    ((and (pred integerp) level)
     (and (<= 1 level (length vocab-level-faces))
          (aref vocab-level-faces (1- level))))
    (_ nil)))

(defun vocab--annotate (beg end word status)
  "Create a vocab-mode overlay for WORD between BEG and END showing STATUS."
  (let ((overlay (make-overlay beg end nil t nil)))
    (overlay-put overlay 'vocab-word word)
    (overlay-put overlay 'evaporate t)
    (vocab--set-overlay-status overlay status)
    overlay))

(defun vocab--set-overlay-status (overlay status)
  "Update OVERLAY to display STATUS."
  (overlay-put overlay 'vocab-status status)
  (overlay-put overlay 'face (vocab--face status)))

(defun vocab--overlays (&optional beg end)
  "Return the vocab-mode overlays between BEG and END, sorted by position.
BEG and END default to the accessible portion of the buffer."
  (sort (seq-filter (lambda (overlay) (overlay-get overlay 'vocab-word))
                    (overlays-in (or beg (point-min)) (or end (point-max))))
        (lambda (a b) (< (overlay-start a) (overlay-start b)))))

(defun vocab--remove-overlays (beg end)
  "Delete vocab-mode overlays between BEG and END, leaving others alone."
  (dolist (overlay (vocab--overlays beg end))
    (delete-overlay overlay)))

(defun vocab-clear-annotations ()
  "Remove every annotation owned by `vocab-mode' from the accessible buffer.
Overlays and text properties created by other packages are untouched."
  (interactive)
  (vocab--remove-overlays (point-min) (point-max)))

(defun vocab--scan-region (beg end)
  "Annotate every word between BEG and END according to its state.
Existing vocab-mode overlays in the region are replaced."
  (save-excursion
    (save-match-data
      (vocab--remove-overlays beg end)
      (let (occurrences words)
        (goto-char beg)
        (while (re-search-forward vocab-word-regexp end t)
          (let ((word (vocab-normalize-word (match-string-no-properties 0))))
            (push (list (match-beginning 0) (match-end 0) word) occurrences)
            (push word words)))
        (vocab--resolve words)
        (dolist (occurrence (nreverse occurrences))
          (pcase-let ((`(,start ,stop ,word) occurrence))
            (vocab--annotate start stop word
                             (gethash word vocab--cache 'unknown)))))))
  ;; Phrases can straddle a line break, so give them the whole lines.
  (vocab--scan-phrases (save-excursion (goto-char beg) (line-beginning-position))
                       (save-excursion (goto-char end) (line-end-position))))

(defun vocab--phrase-regexp (phrase)
  "Return a regexp matching PHRASE, however its words are separated.
Text wraps, so the words of a phrase may be parted by a line break."
  (concat "\\b"
          (mapconcat #'regexp-quote (split-string phrase " " t) "[ \t\n]+")
          "\\b"))

(defun vocab--phrase-overlays (&optional beg end)
  "Return the phrase overlays between BEG and END."
  (seq-filter (lambda (overlay) (overlay-get overlay 'vocab-phrase))
              (vocab--overlays beg end)))

(defun vocab--scan-phrases (beg end)
  "Annotate the stored multi-word entries found between BEG and END.
Phrase overlays sit above the word overlays they cover, so a phrase
reads as one unit while the words below keep their own states."
  (save-excursion
    (save-match-data
      (mapc #'delete-overlay (vocab--phrase-overlays beg end))
      (pcase-dolist (`(,phrase . ,status) (vocab-db-phrases vocab-language))
        (puthash phrase status vocab--cache)
        (let ((regexp (vocab--phrase-regexp phrase))
              (case-fold-search t))
          (goto-char beg)
          (while (re-search-forward regexp end t)
            (let ((overlay (vocab--annotate (match-beginning 0) (match-end 0)
                                            phrase status)))
              (overlay-put overlay 'vocab-phrase t)
              (overlay-put overlay 'priority 10))))))))

(defun vocab--phrase-bounds-at-point ()
  "Return the (BEG . END) bounds of the phrase overlay at point, or nil."
  (let ((overlay (seq-find (lambda (o) (overlay-get o 'vocab-phrase))
                           (overlays-at (point)))))
    (when overlay
      (cons (overlay-start overlay) (overlay-end overlay)))))

(defun vocab-thing-at-point ()
  "Return the phrase or word the commands should act on, or nil.

The active region wins, so selecting text and marking it creates a
multi-word entry.  Failing that, a phrase already annotated at point
wins over the single word inside it, since that is what is highlighted."
  (cond
   ((use-region-p)
    (buffer-substring-no-properties (region-beginning) (region-end)))
   ((vocab--phrase-bounds-at-point)
    (let ((bounds (vocab--phrase-bounds-at-point)))
      (buffer-substring-no-properties (car bounds) (cdr bounds))))
   (t (vocab-word-at-point))))

(defun vocab-refresh-word (word)
  "Refresh every occurrence of WORD in the accessible buffer.
Neither the buffer text nor unrelated annotations are touched."
  (interactive (list (or (vocab-word-at-point) (user-error "No word at point"))))
  (vocab--ensure-enabled)
  (let* ((normalized (vocab-normalize-word word))
         (status (gethash normalized vocab--cache 'unknown)))
    (dolist (overlay (vocab--overlays))
      (when (equal (overlay-get overlay 'vocab-word) normalized)
        (vocab--set-overlay-status overlay status)))))

(defun vocab-refresh-buffer ()
  "Rescan the accessible buffer and reapply current vocabulary states.
Vocabulary states are re-read from the database, so words marked in
another buffer are picked up here."
  (interactive)
  (vocab--ensure-enabled)
  (clrhash vocab--cache)
  (vocab--scan-region (point-min) (point-max)))

;;;; Buffer changes

(defun vocab--changed-region (beg end)
  "Return (BEG . END) grown outwards so that no word is cut in half."
  (save-excursion
    (goto-char beg)
    (while (vocab--letter-at (1- (point)))
      (forward-char -1))
    (let ((start (point)))
      (goto-char (min end (point-max)))
      (while (vocab--letter-at (point))
        (forward-char 1))
      (cons start (point)))))

(defun vocab--render-hook-for-mode ()
  "Return the after-render hook for the current major mode, or nil."
  (cdr (seq-find (lambda (entry) (derived-mode-p (car entry)))
                 vocab-render-hooks)))

(defun vocab--after-render ()
  "Rebuild annotations after the major mode re-rendered the buffer.
Vocabulary states are re-read from the database, so a word marked while
reading one chapter is already known in the next."
  (when (and vocab-mode vocab--cache)
    (with-demoted-errors "vocab-mode: %S"
      (vocab-refresh-buffer))))

(defun vocab--after-change (beg end _pre-length)
  "Rescan the words touched by the change between BEG and END.
Buffers whose major mode renders into them are left to
`vocab--after-render': their content arrives in many small insertions
that are about to be replaced wholesale, so scanning each one is waste."
  (when (and vocab-mode vocab--cache (null vocab--render-hook))
    (with-demoted-errors "vocab-mode: %S"
      (save-match-data
        (let ((region (vocab--changed-region beg end)))
          (vocab--scan-region (car region) (cdr region)))))))

;;;; Commands

(defun vocab--mark (status)
  "Persist STATUS for the phrase or word at point and refresh it.

STATUS is `known', `unknown', or a familiarity level.  `unknown' deletes
the stored row rather than storing a value; any translation of the entry
is kept, since the word means the same whether or not it is known."
  (vocab--ensure-enabled)
  (let ((thing (vocab-thing-at-point)))
    (unless thing (user-error "No word at point"))
    (let ((normalized (vocab-normalize-word thing)))
      (when (string-empty-p normalized)
        (user-error "No word at point"))
      (if (eq status 'unknown)
          (vocab-db-delete-word vocab-language normalized)
        (vocab-db-set-status vocab-language normalized status))
      (puthash normalized status vocab--cache)
      (deactivate-mark)
      (if (vocab-phrase-p normalized)
          ;; A phrase may have just appeared or disappeared, and its
          ;; overlays span text the word refresh does not consider.
          (vocab--scan-phrases (point-min) (point-max))
        (vocab-refresh-word normalized))
      (message "%s — %s" thing (vocab--status-name status)))))

(defun vocab--read-level ()
  "Return the familiarity level the user asked for.
A prefix argument, otherwise the digit key that invoked the command,
otherwise a prompt."
  (let ((prefix (and current-prefix-arg
                     (prefix-numeric-value current-prefix-arg)))
        (key (and (characterp last-command-event)
                  (- last-command-event ?0))))
    (cond
     ((and prefix (<= 1 prefix vocab-db-levels)) prefix)
     ((and key (<= 1 key vocab-db-levels)) key)
     (t (read-number (format "Familiarity level (1-%d): " vocab-db-levels) 1)))))

(defun vocab-mark-level (level)
  "Mark the phrase or word at point with familiarity LEVEL.
Level 1 is a word just met and `vocab-db-levels' one nearly known; each
level is rendered a little more faintly than the one below it."
  (interactive (list (vocab--read-level)))
  (unless (vocab-db-status-p level)
    (user-error "Familiarity level must be between 1 and %d" vocab-db-levels))
  (vocab--mark level))

(defun vocab-show-word ()
  "Show the phrase or word at point and its state in the echo area."
  (interactive)
  (vocab--ensure-enabled)
  (let ((thing (vocab-thing-at-point)))
    (if (not thing)
        (message "No word at point")
      (message "%s — %s" thing (vocab--status-name (vocab-status thing))))))

(defvar vocab--translation-cache (make-hash-table :test #'equal)
  "In-memory translations, keyed by a (LANGUAGE . NORMALIZED-WORD) cons.
Sits in front of the database so a repeated lookup costs nothing at all,
not even a query.")

(defun vocab--translation (language word)
  "Return the known translation of WORD in LANGUAGE, or nil.
Consults the session cache, then the database, remembering what it finds."
  (let ((key (cons language word)))
    (or (gethash key vocab--translation-cache)
        (let ((stored (vocab-db-get-translation language word)))
          (when stored (puthash key stored vocab--translation-cache))))))

(defun vocab--remember-translation (language word translation)
  "Store TRANSLATION of WORD in LANGUAGE, in the database and the cache."
  (vocab-db-set-translation language word translation)
  (puthash (cons language word) translation vocab--translation-cache))

(defun vocab--display-translation (word translation)
  "Display TRANSLATION of WORD, in the echo area or its own buffer.
WORD is prefixed for context unless the backend already opens with it,
as dictionaries and language models tend to."
  (let ((text (string-trim translation)))
    (display-message-or-buffer
     (if (string-prefix-p (downcase word) (downcase text))
         text
       (format "%s — %s" word text))
     "*vocab-translation*")))

(defun vocab-translate-word (&optional refresh)
  "Show a translation of the word at point.

The translation comes from `vocab-translate-function', which is nil
until you configure a backend.  Results are cached; with a prefix
argument REFRESH, ask the backend again instead of reusing the cache."
  (interactive "P")
  (vocab--ensure-enabled)
  (unless (functionp vocab-translate-function)
    (user-error "No translation backend; set `vocab-translate-function'"))
  (let ((thing (vocab-thing-at-point)))
    (unless thing (user-error "No word at point"))
    (let* ((normalized (vocab-normalize-word thing))
           (language vocab-language)
           (known (and (not refresh) (vocab--translation language normalized))))
      (if known
          (vocab--display-translation thing known)
        (message "Translating %s..." thing)
        (funcall vocab-translate-function thing language
                 (lambda (translation)
                   (if (and (stringp translation)
                            (not (string-blank-p translation)))
                       (progn
                         (vocab--remember-translation language normalized
                                                      translation)
                         (vocab--display-translation thing translation))
                     (message "No translation for %s" thing))))))))

(defun vocab-clear-translation-cache ()
  "Drop the in-memory translations, keeping the stored ones.
The next lookup reads them back from the database."
  (interactive)
  (clrhash vocab--translation-cache)
  (message "Translation cache cleared"))

(defun vocab-forget-translation ()
  "Delete the stored translation of the phrase or word at point."
  (interactive)
  (vocab--ensure-enabled)
  (let ((thing (vocab-thing-at-point)))
    (unless thing (user-error "No word at point"))
    (let ((normalized (vocab-normalize-word thing)))
      (vocab-db-delete-translation vocab-language normalized)
      (remhash (cons vocab-language normalized) vocab--translation-cache)
      (message "Forgot the translation of %s" thing))))

(defun vocab-mark-known ()
  "Mark the phrase or word at point as known, persistently."
  (interactive)
  (vocab--mark 'known))

(defun vocab-mark-learning ()
  "Mark the phrase or word at point as just met: familiarity level 1."
  (interactive)
  (vocab--mark 1))

(defun vocab-mark-unknown ()
  "Mark the phrase or word at point as unknown, deleting its stored row.
Any translation it has is kept."
  (interactive)
  (vocab--mark 'unknown))

(defun vocab--unknown-overlays ()
  "Return the unknown-word overlays of the accessible buffer, in order."
  (seq-filter (lambda (overlay) (eq (overlay-get overlay 'vocab-status) 'unknown))
              (vocab--overlays)))

(defun vocab--goto-unknown (backward)
  "Move point to the next unknown word, or the previous one when BACKWARD."
  (vocab--ensure-enabled)
  (let* ((overlays (vocab--unknown-overlays))
         (candidates (if backward
                         (nreverse (seq-take-while
                                    (lambda (o) (< (overlay-start o) (point)))
                                    overlays))
                       (seq-drop-while (lambda (o) (<= (overlay-start o) (point)))
                                       overlays)))
         (wrapped (null candidates))
         (target (car (or candidates
                          (if backward (last overlays) overlays)))))
    (cond
     ((null target) (message "No unknown words"))
     (t (goto-char (overlay-start target))
        (when wrapped (message "Wrapped"))
        (point)))))

(defun vocab-next-unknown ()
  "Move point to the beginning of the next unknown word, wrapping around."
  (interactive)
  (vocab--goto-unknown nil))

(defun vocab-previous-unknown ()
  "Move point to the beginning of the previous unknown word, wrapping around."
  (interactive)
  (vocab--goto-unknown t))

;;;; Mode

(defun vocab--language-candidates ()
  "Return the languages worth offering for completion, sorted.
Those already in the database, plus any entered earlier this session."
  (sort (delete-dups (append (vocab-db-languages)
                             (copy-sequence vocab-language-history)))
        #'string<))

(defun vocab--lighter ()
  "Return the mode-line lighter, naming the language being read.
Evaluated during redisplay, so it follows `vocab-language' by itself.
Redefine this function to change how the mode announces itself."
  (if (and (stringp vocab-language) (not (string-empty-p vocab-language)))
      (format " Vocab[%s]" vocab-language)
    " Vocab"))

(defun vocab--read-language ()
  "Prompt for and return the target language of this buffer.

Completion offers the languages already in use and defaults to the last
one entered, but the set is not fixed: any string is accepted, and case
does not matter, since `Suomi' and `suomi' are one language."
  (let* ((candidates (vocab--language-candidates))
         (default (or (car vocab-language-history) (car candidates)))
         (completion-ignore-case t)
         (language (string-trim
                    (completing-read (format-prompt "Language" default)
                                     candidates nil nil nil
                                     'vocab-language-history default))))
    (when (string-empty-p language)
      (user-error "A target language is required"))
    (downcase language)))

(defun vocab--enable ()
  "Set up `vocab-mode' in the current buffer."
  (vocab-db-ensure-available)
  (unless (and (stringp vocab-language) (not (string-empty-p vocab-language)))
    (setq vocab-language (vocab--read-language)))
  (setq vocab-language (downcase vocab-language))
  (vocab-db-open)
  (setq vocab--cache (make-hash-table :test #'equal))
  (setq vocab--render-hook (vocab--render-hook-for-mode))
  (when vocab--render-hook
    (add-hook vocab--render-hook #'vocab--after-render nil t))
  (add-hook 'after-change-functions #'vocab--after-change nil t)
  (vocab--scan-region (point-min) (point-max)))

(defun vocab--disable ()
  "Tear down `vocab-mode' in the current buffer, leaving the text alone."
  (remove-hook 'after-change-functions #'vocab--after-change t)
  (when vocab--render-hook
    (remove-hook vocab--render-hook #'vocab--after-render t)
    (setq vocab--render-hook nil))
  (save-restriction
    (widen)
    (vocab--remove-overlays (point-min) (point-max)))
  (setq vocab--cache nil))

;;;###autoload
(define-minor-mode vocab-mode
  "Add persistent vocabulary-learning annotations to the current buffer.

Words absent from the vocabulary database are shown with
`vocab-unknown-face', words being learned with `vocab-learning-face',
and known words keep their ordinary appearance.  The buffer text is
never modified, so read-only buffers are fully supported.

No keys are bound by default; see `vocab-mode-map' and
`vocab-mode-bind-reading-keys'.

\\{vocab-mode-map}"
  :lighter (:eval (vocab--lighter))
  :keymap vocab-mode-map
  :group 'vocab
  (if vocab-mode
      (condition-case err
          (vocab--enable)
        (error
         (vocab--disable)
         (setq vocab-mode nil)
         (signal (car err) (cdr err))))
    (vocab--disable)))

(provide 'vocab-mode)
;;; vocab-mode.el ends here
