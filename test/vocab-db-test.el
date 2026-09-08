;;; vocab-db-test.el --- Tests for vocab-db  -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for the persistence layer.  Every test runs against a fresh
;; temporary database; the user's real vocabulary file is never opened.

;;; Code:

(require 'ert)
(require 'vocab-db)

(defmacro vocab-db-test--with-db (&rest body)
  "Run BODY with `vocab-database-file' bound to a fresh temporary database."
  (declare (indent 0) (debug t))
  `(let* ((vocab-db-test--dir (make-temp-file "vocab-db-test" t))
          (vocab-database-file
           (expand-file-name "vocab/vocab.sqlite" vocab-db-test--dir)))
     (unwind-protect
         (progn ,@body)
       (vocab-db-close-all)
       (delete-directory vocab-db-test--dir t))))

(ert-deftest vocab-db-test-creates-database-and-parent-directory ()
  (vocab-db-test--with-db
    (should-not (file-exists-p vocab-database-file))
    (should (sqlitep (vocab-db-open)))
    (should (file-exists-p vocab-database-file))))

(ert-deftest vocab-db-test-initializes-schema ()
  (vocab-db-test--with-db
    (let ((db (vocab-db-open)))
      (should (equal (sqlite-select db "SELECT name FROM sqlite_master \
WHERE type = 'table' AND name = 'vocabulary'")
                     '(("vocabulary"))))
      ;; Re-opening an existing database must not recreate it.
      (vocab-db-set-status "german" "hund" 'known)
      (vocab-db-close)
      (vocab-db-open)
      (should (eq (vocab-db-get-status "german" "hund") 'known)))))

(ert-deftest vocab-db-test-absent-word-is-unknown ()
  (vocab-db-test--with-db
    (should-not (vocab-db-get-status "german" "hund"))))

(ert-deftest vocab-db-test-insert-known ()
  (vocab-db-test--with-db
    (vocab-db-set-status "german" "hund" 'known)
    (should (eq (vocab-db-get-status "german" "hund") 'known))))

(ert-deftest vocab-db-test-insert-learning ()
  (vocab-db-test--with-db
    (vocab-db-set-status "german" "langsam" 'learning)
    (should (eq (vocab-db-get-status "german" "langsam") 'learning))))

(ert-deftest vocab-db-test-learning-to-known ()
  (vocab-db-test--with-db
    (vocab-db-set-status "german" "hund" 'learning)
    (vocab-db-set-status "german" "hund" 'known)
    (should (eq (vocab-db-get-status "german" "hund") 'known))
    (should (= 1 (caar (sqlite-select (vocab-db-open)
                                      "SELECT count(*) FROM vocabulary"))))))

(ert-deftest vocab-db-test-known-to-learning ()
  (vocab-db-test--with-db
    (vocab-db-set-status "german" "hund" 'known)
    (vocab-db-set-status "german" "hund" 'learning)
    (should (eq (vocab-db-get-status "german" "hund") 'learning))))

(ert-deftest vocab-db-test-delete-returns-word-to-unknown ()
  (vocab-db-test--with-db
    (vocab-db-set-status "german" "hund" 'known)
    (vocab-db-delete-word "german" "hund")
    (should-not (vocab-db-get-status "german" "hund"))))

(ert-deftest vocab-db-test-delete-of-absent-word-is-harmless ()
  (vocab-db-test--with-db
    (vocab-db-set-status "german" "katze" 'known)
    (vocab-db-delete-word "german" "hund")
    (should (eq (vocab-db-get-status "german" "katze") 'known))))

(ert-deftest vocab-db-test-language-isolation ()
  (vocab-db-test--with-db
    (vocab-db-set-status "german" "die" 'known)
    (should (eq (vocab-db-get-status "german" "die") 'known))
    (should-not (vocab-db-get-status "french" "die"))
    (vocab-db-set-status "french" "die" 'learning)
    (should (eq (vocab-db-get-status "german" "die") 'known))
    (should (eq (vocab-db-get-status "french" "die") 'learning))))

(ert-deftest vocab-db-test-languages ()
  (vocab-db-test--with-db
    (should-not (vocab-db-languages))
    (vocab-db-set-status "russian" "ёжик" 'known)
    (vocab-db-set-status "german" "hund" 'known)
    (vocab-db-set-status "german" "katze" 'learning)
    (should (equal (vocab-db-languages) '("german" "russian")))))

(ert-deftest vocab-db-test-batched-lookup ()
  (vocab-db-test--with-db
    (vocab-db-set-status "german" "der" 'known)
    (vocab-db-set-status "german" "langsam" 'learning)
    (vocab-db-set-status "french" "der" 'known)
    (let ((statuses (vocab-db-get-statuses
                     "german" '("der" "hund" "langsam" "der"))))
      (should (eq (gethash "der" statuses) 'known))
      (should (eq (gethash "langsam" statuses) 'learning))
      ;; Unknown words are absent rather than stored.
      (should-not (gethash "hund" statuses))
      (should (= 2 (hash-table-count statuses))))))

(ert-deftest vocab-db-test-batched-lookup-handles-many-words ()
  (vocab-db-test--with-db
    (let ((words (mapcar (lambda (i) (format "wort%d" i)) (number-sequence 1 1000))))
      (vocab-db-set-status "german" "wort500" 'known)
      (let ((statuses (vocab-db-get-statuses "german" words)))
        (should (= 1 (hash-table-count statuses)))
        (should (eq (gethash "wort500" statuses) 'known))))))

(ert-deftest vocab-db-test-rejects-invalid-status ()
  (vocab-db-test--with-db
    (should-error (vocab-db-set-status "german" "hund" 'unknown)
                  :type 'vocab-db-error)
    (should-error (vocab-db-set-status "german" "hund" 'nonsense)
                  :type 'vocab-db-error)
    (should (= 0 (caar (sqlite-select (vocab-db-open)
                                      "SELECT count(*) FROM vocabulary"))))))

(ert-deftest vocab-db-test-scanning-does-not-write ()
  "Resolving statuses for a large vocabulary must not create rows."
  (vocab-db-test--with-db
    (vocab-db-get-statuses
     "german" (mapcar (lambda (i) (format "wort%d" i)) (number-sequence 1 2000)))
    (should (= 0 (caar (sqlite-select (vocab-db-open)
                                      "SELECT count(*) FROM vocabulary"))))))

(ert-deftest vocab-db-test-errors-do-not-destroy-data ()
  "A failing query surfaces a `vocab-db-error' and leaves rows intact."
  (vocab-db-test--with-db
    (vocab-db-set-status "german" "hund" 'known)
    (should-error (sqlite-select (vocab-db-open) "SELECT * FROM nope"))
    (should (eq (vocab-db-get-status "german" "hund") 'known))))

(provide 'vocab-db-test)
;;; vocab-db-test.el ends here
