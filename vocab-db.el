;;; vocab-db.el --- SQLite persistence for vocab-mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Simo-Pekka Kerkelä

;; Author: Simo-Pekka Kerkelä
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, convenience

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Persistence layer for `vocab-mode'.  This file knows about SQLite and
;; vocabulary states; it knows nothing about buffers, overlays or faces.
;;
;; A word is stored only when the user explicitly marks it `learning' or
;; `known'.  Absence from the database means `unknown', so scanning a
;; document never writes anything.

;;; Code:

(require 'seq)

(defgroup vocab nil
  "Persistent vocabulary-learning annotations for arbitrary buffers."
  :group 'applications
  :prefix "vocab-")

(defcustom vocab-database-file
  (expand-file-name "vocab/vocab.sqlite" user-emacs-directory)
  "File holding the persistent vocabulary database.
The parent directory and the database itself are created on demand."
  :type 'file
  :group 'vocab)

(define-error 'vocab-db-error "vocab-mode database error")

(defconst vocab-db-levels 4
  "Number of familiarity levels between unknown and known.
Level 1 is a word just met, level `vocab-db-levels' one nearly known.")

(defconst vocab-db--legacy-statuses '(("learning" . 1))
  "Stored statuses from earlier versions and the level they now mean.
Rows are read through this map and left untouched on disk, so a database
written by an older `vocab-mode' keeps working and loses nothing.")

(defun vocab-db-status-p (status)
  "Return non-nil when STATUS is a state that can be stored.
That is `known', or a familiarity level from 1 to `vocab-db-levels'.
Absence from the database means `unknown', which is never stored."
  (or (eq status 'known)
      (and (integerp status) (<= 1 status vocab-db-levels))))

(defconst vocab-db--chunk-size 400
  "Maximum number of words per batched lookup query.
Keeps the number of SQL placeholders well below SQLite's limit.")

(defvar vocab-db--connections (make-hash-table :test #'equal)
  "Hash mapping absolute database file names to open SQLite connections.")

;;; Availability

(defun vocab-db-available-p ()
  "Return non-nil when this Emacs can use SQLite."
  (and (fboundp 'sqlite-available-p) (sqlite-available-p)))

(defun vocab-db-ensure-available ()
  "Signal a user error unless SQLite support is available."
  (unless (vocab-db-available-p)
    (user-error
     "vocab-mode requires an Emacs built with SQLite support (Emacs 29.1 or later)")))

;;; Connections

(defun vocab-db-file (&optional file)
  "Return the absolute name of FILE, defaulting to `vocab-database-file'."
  (expand-file-name (or file vocab-database-file)))

(defmacro vocab-db--protect (description &rest body)
  "Evaluate BODY, converting SQLite failures into a `vocab-db-error'.
DESCRIPTION names the operation being attempted."
  (declare (indent 1) (debug (form body)))
  `(condition-case err
       (progn ,@body)
     (vocab-db-error (signal (car err) (cdr err)))
     (error
      (signal 'vocab-db-error
              (list (format "%s failed: %s" ,description
                            (error-message-string err)))))))

(defun vocab-db--init-schema (db)
  "Create the vocabulary table in DB unless it already exists."
  (sqlite-execute db "\
CREATE TABLE IF NOT EXISTS vocabulary (
    language TEXT NOT NULL,
    word TEXT NOT NULL,
    status TEXT NOT NULL,
    PRIMARY KEY (language, word)
)")
  (sqlite-execute db "\
CREATE TABLE IF NOT EXISTS translations (
    language TEXT NOT NULL,
    word TEXT NOT NULL,
    translation TEXT NOT NULL,
    PRIMARY KEY (language, word)
)"))

(defun vocab-db-open (&optional file)
  "Return an open connection to FILE, defaulting to `vocab-database-file'.
The parent directory, the database file and the schema are created when
missing.  Connections are cached, so repeated calls are cheap.  An
existing database is never dropped or recreated."
  (vocab-db-ensure-available)
  (let* ((path (vocab-db-file file))
         (db (gethash path vocab-db--connections)))
    (or (and db (sqlitep db) db)
        (vocab-db--protect (format "Opening vocabulary database %s" path)
          (let ((dir (file-name-directory path)))
            (when (and dir (not (file-directory-p dir)))
              (make-directory dir t)))
          (let ((new (sqlite-open path)))
            (vocab-db--init-schema new)
            (puthash path new vocab-db--connections)
            new)))))

(defun vocab-db-close (&optional file)
  "Close the cached connection to FILE, if any."
  (let* ((path (vocab-db-file file))
         (db (gethash path vocab-db--connections)))
    (when db
      (remhash path vocab-db--connections)
      (when (sqlitep db) (sqlite-close db)))))

(defun vocab-db-close-all ()
  "Close every cached database connection."
  (maphash (lambda (path _db) (vocab-db-close path))
           (copy-hash-table vocab-db--connections)))

;;; Statuses

(defun vocab-db--status-string (status)
  "Return the stored string for STATUS, or signal an error."
  (unless (vocab-db-status-p status)
    (signal 'vocab-db-error
            (list (format "Refusing to store invalid vocabulary status: %S"
                          status))))
  (if (eq status 'known) "known" (number-to-string status)))

(defun vocab-db--status-value (string)
  "Return the status STRING means, or nil when it means nothing storable.
Understands the levels and `known' written today, and the statuses of
earlier versions."
  (when (stringp string)
    (cond
     ((equal string "known") 'known)
     ((cdr (assoc string vocab-db--legacy-statuses)))
     ((string-match-p "\\`[0-9]+\\'" string)
      (let ((level (string-to-number string)))
        (and (<= 1 level vocab-db-levels) level))))))

(defun vocab-db-get-status (language word &optional file)
  "Return the stored status of WORD in LANGUAGE, or nil when absent.
A nil result means the word is unknown.  FILE defaults to
`vocab-database-file'."
  (let ((db (vocab-db-open file)))
    (vocab-db--protect "Reading vocabulary"
      (vocab-db--status-value
       (caar (sqlite-select
              db "SELECT status FROM vocabulary WHERE language = ? AND word = ?"
              (list language word)))))))

(defun vocab-db-get-statuses (language words &optional file)
  "Return a hash table mapping each of WORDS to its status in LANGUAGE.
Only stored words are present in the table; absent words are unknown and
are deliberately not inserted.  FILE defaults to `vocab-database-file'."
  (let ((db (vocab-db-open file))
        (table (make-hash-table :test #'equal))
        (remaining (delete-dups (copy-sequence words))))
    (vocab-db--protect "Reading vocabulary"
      (while remaining
        (let* ((chunk (seq-take remaining vocab-db--chunk-size))
               (placeholders (string-join (make-list (length chunk) "?") ",")))
          (setq remaining (seq-drop remaining vocab-db--chunk-size))
          (dolist (row (sqlite-select
                        db (format "SELECT word, status FROM vocabulary \
WHERE language = ? AND word IN (%s)" placeholders)
                        (cons language chunk)))
            (let ((status (vocab-db--status-value (cadr row))))
              (when status (puthash (car row) status table)))))))
    table))

(defun vocab-db-languages (&optional file)
  "Return the languages that have vocabulary stored, sorted alphabetically.
FILE defaults to `vocab-database-file'."
  (let ((db (vocab-db-open file)))
    (vocab-db--protect "Reading vocabulary"
      (mapcar #'car (sqlite-select
                     db "SELECT DISTINCT language FROM vocabulary ORDER BY language")))))

(defun vocab-db-set-status (language word status &optional file)
  "Persist STATUS for WORD in LANGUAGE.
STATUS must be `learning' or `known'; `unknown' is represented by the
absence of a row, see `vocab-db-delete-word'."
  (let ((db (vocab-db-open file))
        (stored (vocab-db--status-string status)))
    (vocab-db--protect "Writing vocabulary"
      (sqlite-execute db "\
INSERT INTO vocabulary (language, word, status) VALUES (?, ?, ?)
ON CONFLICT (language, word) DO UPDATE SET status = excluded.status"
                      (list language word stored)))
    stored))

(defun vocab-db-delete-word (language word &optional file)
  "Delete the row for WORD in LANGUAGE, returning the word to unknown."
  (let ((db (vocab-db-open file)))
    (vocab-db--protect "Deleting vocabulary"
      (sqlite-execute db "DELETE FROM vocabulary WHERE language = ? AND word = ?"
                      (list language word)))))

(defun vocab-db-phrases (language &optional file)
  "Return the stored multi-word entries of LANGUAGE and their statuses.
The result is an alist of (PHRASE . STATUS).  A phrase is any entry
holding a space, so phrases need no table of their own."
  (let ((db (vocab-db-open file)))
    (vocab-db--protect "Reading vocabulary"
      (delq nil
            (mapcar (lambda (row)
                      (let ((status (vocab-db--status-value (cadr row))))
                        (and status (cons (car row) status))))
                    (sqlite-select
                     db "SELECT word, status FROM vocabulary \
WHERE language = ? AND word LIKE '% %' ORDER BY length(word) DESC"
                     (list language)))))))

;;; Translations

(defun vocab-db-get-translation (language word &optional file)
  "Return the stored translation of WORD in LANGUAGE, or nil."
  (let ((db (vocab-db-open file)))
    (vocab-db--protect "Reading translations"
      (caar (sqlite-select
             db "SELECT translation FROM translations \
WHERE language = ? AND word = ?"
             (list language word))))))

(defun vocab-db-set-translation (language word translation &optional file)
  "Store TRANSLATION of WORD in LANGUAGE, replacing any earlier one."
  (let ((db (vocab-db-open file)))
    (vocab-db--protect "Writing translations"
      (sqlite-execute db "\
INSERT INTO translations (language, word, translation) VALUES (?, ?, ?)
ON CONFLICT (language, word) DO UPDATE SET translation = excluded.translation"
                      (list language word translation)))
    translation))

(defun vocab-db-delete-translation (language word &optional file)
  "Delete the stored translation of WORD in LANGUAGE."
  (let ((db (vocab-db-open file)))
    (vocab-db--protect "Deleting translations"
      (sqlite-execute db "DELETE FROM translations \
WHERE language = ? AND word = ?"
                      (list language word)))))

(provide 'vocab-db)
;;; vocab-db.el ends here
