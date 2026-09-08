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

(defconst vocab-db--statuses '(learning known)
  "Vocabulary states that are stored persistently.
Absence from the database means `unknown'.")

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
  (let ((sym (if (stringp status) (intern status) status)))
    (unless (memq sym vocab-db--statuses)
      (signal 'vocab-db-error
              (list (format "Refusing to store invalid vocabulary status: %S"
                            status))))
    (symbol-name sym)))

(defun vocab-db--status-symbol (string)
  "Return the status symbol for STRING, or nil when it is not storable."
  (and (stringp string)
       (let ((sym (intern string)))
         (and (memq sym vocab-db--statuses) sym))))

(defun vocab-db-get-status (language word &optional file)
  "Return the stored status of WORD in LANGUAGE, or nil when absent.
A nil result means the word is unknown.  FILE defaults to
`vocab-database-file'."
  (let ((db (vocab-db-open file)))
    (vocab-db--protect "Reading vocabulary"
      (vocab-db--status-symbol
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
            (let ((status (vocab-db--status-symbol (cadr row))))
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

(provide 'vocab-db)
;;; vocab-db.el ends here
