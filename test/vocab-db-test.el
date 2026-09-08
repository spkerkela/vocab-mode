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

(ert-deftest vocab-db-test-insert-level ()
  (vocab-db-test--with-db
    (dolist (level (number-sequence 1 vocab-db-levels))
      (vocab-db-set-status "german" "langsam" level)
      (should (eql (vocab-db-get-status "german" "langsam") level)))))

(ert-deftest vocab-db-test-legacy-learning-reads-as-level-1 ()
  "A database written by an earlier version must keep working, untouched."
  (vocab-db-test--with-db
    (sqlite-execute (vocab-db-open)
                    "INSERT INTO vocabulary VALUES (?, ?, ?)"
                    (list "german" "hund" "learning"))
    (should (eql (vocab-db-get-status "german" "hund") 1))
    (should (eql (gethash "hund" (vocab-db-get-statuses "german" '("hund"))) 1))
    ;; The row itself is left as it was found.
    (should (equal (caar (sqlite-select (vocab-db-open)
                                        "SELECT status FROM vocabulary \
WHERE word = 'hund'"))
                   "learning"))))

(ert-deftest vocab-db-test-learning-to-known ()
  (vocab-db-test--with-db
    (vocab-db-set-status "german" "hund" 1)
    (vocab-db-set-status "german" "hund" 'known)
    (should (eq (vocab-db-get-status "german" "hund") 'known))
    (should (= 1 (caar (sqlite-select (vocab-db-open)
                                      "SELECT count(*) FROM vocabulary"))))))

(ert-deftest vocab-db-test-known-to-learning ()
  (vocab-db-test--with-db
    (vocab-db-set-status "german" "hund" 'known)
    (vocab-db-set-status "german" "hund" 3)
    (should (eql (vocab-db-get-status "german" "hund") 3))))

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
    (vocab-db-set-status "french" "die" 2)
    (should (eq (vocab-db-get-status "german" "die") 'known))
    (should (eql (vocab-db-get-status "french" "die") 2))))

(ert-deftest vocab-db-test-languages ()
  (vocab-db-test--with-db
    (should-not (vocab-db-languages))
    (vocab-db-set-status "russian" "ёжик" 'known)
    (vocab-db-set-status "german" "hund" 'known)
    (vocab-db-set-status "german" "katze" 2)
    (should (equal (vocab-db-languages) '("german" "russian")))))

(ert-deftest vocab-db-test-batched-lookup ()
  (vocab-db-test--with-db
    (vocab-db-set-status "german" "der" 'known)
    (vocab-db-set-status "german" "langsam" 2)
    (vocab-db-set-status "french" "der" 'known)
    (let ((statuses (vocab-db-get-statuses
                     "german" '("der" "hund" "langsam" "der"))))
      (should (eq (gethash "der" statuses) 'known))
      (should (eql (gethash "langsam" statuses) 2))
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
    (should-error (vocab-db-set-status "german" "hund" 0)
                  :type 'vocab-db-error)
    (should-error (vocab-db-set-status "german" "hund" (1+ vocab-db-levels))
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

(ert-deftest vocab-db-test-phrases ()
  (vocab-db-test--with-db
    (vocab-db-set-status "russian" "ёжик" 1)
    (vocab-db-set-status "russian" "как дела" 2)
    (vocab-db-set-status "russian" "я не знаю" 'known)
    (vocab-db-set-status "german" "guten tag" 1)
    (should (equal (vocab-db-phrases "russian")
                   '(("я не знаю" . known) ("как дела" . 2))))
    (should (equal (vocab-db-phrases "german") '(("guten tag" . 1))))
    (should-not (vocab-db-phrases "french"))))

(ert-deftest vocab-db-test-translations ()
  (vocab-db-test--with-db
    (should-not (vocab-db-get-translation "russian" "ёжик"))
    (vocab-db-set-translation "russian" "ёжик" "hedgehog")
    (should (equal (vocab-db-get-translation "russian" "ёжик") "hedgehog"))
    ;; Replacing keeps one row.
    (vocab-db-set-translation "russian" "ёжик" "a hedgehog")
    (should (equal (vocab-db-get-translation "russian" "ёжик") "a hedgehog"))
    (should (= 1 (caar (sqlite-select (vocab-db-open)
                                      "SELECT count(*) FROM translations"))))
    ;; Languages and phrases are independent.
    (should-not (vocab-db-get-translation "german" "ёжик"))
    (vocab-db-set-translation "russian" "как дела" "how are you")
    (should (equal (vocab-db-get-translation "russian" "как дела")
                   "how are you"))
    (vocab-db-delete-translation "russian" "ёжик")
    (should-not (vocab-db-get-translation "russian" "ёжик"))
    (should (equal (vocab-db-get-translation "russian" "как дела")
                   "how are you"))))

(ert-deftest vocab-db-test-marking-unknown-keeps-the-translation ()
  (vocab-db-test--with-db
    (vocab-db-set-status "russian" "ёжик" 'known)
    (vocab-db-set-translation "russian" "ёжик" "hedgehog")
    (vocab-db-delete-word "russian" "ёжик")
    (should-not (vocab-db-get-status "russian" "ёжик"))
    (should (equal (vocab-db-get-translation "russian" "ёжик") "hedgehog"))))

(ert-deftest vocab-db-test-errors-do-not-destroy-data ()
  "A failing query surfaces a `vocab-db-error' and leaves rows intact."
  (vocab-db-test--with-db
    (vocab-db-set-status "german" "hund" 'known)
    (should-error (sqlite-select (vocab-db-open) "SELECT * FROM nope"))
    (should (eq (vocab-db-get-status "german" "hund") 'known))))

(provide 'vocab-db-test)
;;; vocab-db-test.el ends here
