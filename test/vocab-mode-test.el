;;; vocab-mode-test.el --- Tests for vocab-mode  -*- lexical-binding: t; -*-

;;; Commentary:

;; ERT tests for word detection, normalization, annotations, navigation
;; and the mode lifecycle.  Every test runs against a fresh temporary
;; database; the user's real vocabulary file is never opened.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'eww)
(require 'vocab-mode)

(defmacro vocab-mode-test--with-db (&rest body)
  "Run BODY with `vocab-database-file' bound to a fresh temporary database."
  (declare (indent 0) (debug t))
  `(let* ((vocab-mode-test--dir (make-temp-file "vocab-mode-test" t))
          (vocab-database-file
           (expand-file-name "vocab/vocab.sqlite" vocab-mode-test--dir)))
     (unwind-protect
         (progn ,@body)
       (vocab-db-close-all)
       (delete-directory vocab-mode-test--dir t))))

(defmacro vocab-mode-test--with-buffer (text &rest body)
  "Run BODY in a temporary `text-mode' German buffer containing TEXT.
`vocab-mode' is enabled and point starts at the beginning of the buffer."
  (declare (indent 1) (debug t))
  `(with-temp-buffer
     (text-mode)
     (insert ,text)
     (goto-char (point-min))
     (setq vocab-language "german")
     (vocab-mode 1)
     ,@body))

(defun vocab-mode-test--statuses ()
  "Return (WORD . STATUS) for every annotation in the buffer, in order."
  (mapcar (lambda (overlay)
            (cons (buffer-substring-no-properties
                   (overlay-start overlay) (overlay-end overlay))
                  (overlay-get overlay 'vocab-status)))
          (vocab--overlays)))

(defun vocab-mode-test--faces ()
  "Return the face of every annotation in the buffer, in order."
  (mapcar (lambda (overlay) (overlay-get overlay 'face)) (vocab--overlays)))

(defun vocab-mode-test--message-of (command)
  "Call COMMAND and return the text it echoed."
  (let (captured)
    (cl-letf (((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq captured (and format-string
                                     (apply #'format format-string args))))))
      (funcall command))
    captured))

(defun vocab-mode-test--goto-word (word &optional occurrence)
  "Move point onto the OCCURRENCE-th (default first) WORD of the buffer.
The search is case-sensitive, so \"HUND\" does not land on \"Hund\"."
  (goto-char (point-min))
  (let ((case-fold-search nil))
    (search-forward word nil nil (or occurrence 1)))
  (goto-char (match-beginning 0)))

;;;; Normalization

(ert-deftest vocab-mode-test-normalize-downcases ()
  (should (equal (vocab-normalize-word "Haus") "haus"))
  (should (equal (vocab-normalize-word "HAUS") "haus"))
  (should (equal (vocab-normalize-word "haus") "haus")))

(ert-deftest vocab-mode-test-normalize-unicode ()
  (should (equal (vocab-normalize-word "Grüße") "grüße"))
  (should (equal (vocab-normalize-word "ÄPFEL") "äpfel"))
  (should (equal (vocab-normalize-word "Ystävä") "ystävä"))
  (should (equal (vocab-normalize-word "ΛΌΓΟΣ") "λόγος")))

;;;; Word detection

(ert-deftest vocab-mode-test-word-at-point-skips-punctuation ()
  (with-temp-buffer
    (insert "Hallo, Welt!")
    (vocab-mode-test--goto-word "Hallo")
    (should (equal (vocab-word-at-point) "Hallo"))
    (vocab-mode-test--goto-word "Welt")
    (should (equal (vocab-word-at-point) "Welt"))
    ;; On the comma and on the space there is no word after point, but the
    ;; letter before point still counts.
    (goto-char (point-min))
    (search-forward "Hallo")
    (should (equal (vocab-word-at-point) "Hallo"))))

(ert-deftest vocab-mode-test-word-at-point-inside-word ()
  (with-temp-buffer
    (insert "Der Hund.")
    (goto-char (point-min))
    (search-forward "Hu")
    (should (equal (vocab-word-at-point) "Hund"))))

(ert-deftest vocab-mode-test-word-at-point-various-delimiters ()
  (dolist (case '(("(Hund)" . "Hund")
                  ("\"Hund\"" . "Hund")
                  ("»Hund«" . "Hund")
                  ("„Hund“" . "Hund")
                  ("Hund." . "Hund")
                  ("Hund…" . "Hund")
                  ("—Hund—" . "Hund")
                  ("Hund;" . "Hund")))
    (with-temp-buffer
      (insert (car case))
      (vocab-mode-test--goto-word (cdr case))
      (should (equal (vocab-word-at-point) (cdr case))))))

(ert-deftest vocab-mode-test-word-at-point-unicode ()
  (with-temp-buffer
    (insert "Die Grüße, mon ami — ystävä!")
    (vocab-mode-test--goto-word "Grüße")
    (should (equal (vocab-word-at-point) "Grüße"))
    (vocab-mode-test--goto-word "ystävä")
    (should (equal (vocab-word-at-point) "ystävä"))))

(ert-deftest vocab-mode-test-word-at-point-none ()
  (with-temp-buffer
    (insert "   ...   ")
    (goto-char (point-min))
    (should-not (vocab-word-at-point))
    (goto-char (+ 5 (point-min)))
    (should-not (vocab-word-at-point))))

(ert-deftest vocab-mode-test-word-at-point-respects-narrowing ()
  (with-temp-buffer
    (insert "Hundehütte")
    (narrow-to-region (+ (point-min) 4) (point-max))
    (goto-char (point-min))
    (should (equal (vocab-word-at-point) "ehütte"))))

;;;; Lifecycle

(ert-deftest vocab-mode-test-keeps-major-mode-and-text ()
  (vocab-mode-test--with-db
    (let ((text "Der Hund sieht den Hund."))
      (vocab-mode-test--with-buffer text
        (should (eq major-mode 'text-mode))
        (should vocab-mode)
        (should (equal (buffer-string) text))
        (vocab-mode -1)
        (should (eq major-mode 'text-mode))
        (should (equal (buffer-string) text))))))

(ert-deftest vocab-mode-test-detects-and-annotates-words ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund sieht den Hund."
      (should (equal (vocab-mode-test--statuses)
                     '(("Der" . unknown) ("Hund" . unknown) ("sieht" . unknown)
                       ("den" . unknown) ("Hund" . unknown))))
      (should (equal (vocab-mode-test--faces)
                     (make-list 5 'vocab-unknown-face))))))

(ert-deftest vocab-mode-test-marking-known-updates-every-occurrence ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund sieht den HUND und hund."
      (vocab-mode-test--goto-word "Hund")
      (vocab-mark-known)
      (should (equal (vocab-mode-test--statuses)
                     '(("Der" . unknown) ("Hund" . known) ("sieht" . unknown)
                       ("den" . unknown) ("HUND" . known) ("und" . unknown)
                       ("hund" . known))))
      ;; Known words carry no face of their own.
      (should-not (overlay-get (nth 1 (vocab--overlays)) 'face))
      (should (equal (buffer-string) "Der Hund sieht den HUND und hund.")))))

(ert-deftest vocab-mode-test-marking-learning-and-back-to-unknown ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund sieht den Hund."
      (vocab-mode-test--goto-word "Hund")
      (vocab-mark-learning)
      (should (equal (vocab-mode-test--statuses)
                     '(("Der" . unknown) ("Hund" . learning) ("sieht" . unknown)
                       ("den" . unknown) ("Hund" . learning))))
      (should (eq (nth 1 (vocab-mode-test--faces)) 'vocab-learning-face))
      (should (eq (vocab-db-get-status "german" "hund") 'learning))
      (vocab-mark-unknown)
      (should (eq (vocab-status "Hund") 'unknown))
      (should-not (vocab-db-get-status "german" "hund"))
      (should (equal (vocab-mode-test--faces)
                     (make-list 5 'vocab-unknown-face))))))

(ert-deftest vocab-mode-test-disabling-removes-only-own-annotations ()
  (vocab-mode-test--with-db
    (let ((text "Der Hund sieht den Hund."))
      (with-temp-buffer
        (text-mode)
        (insert text)
        (put-text-property (point-min) (+ (point-min) 3) 'face 'bold)
        (put-text-property (point-min) (+ (point-min) 3) 'my-property 'kept)
        (let ((foreign (make-overlay (point-min) (+ (point-min) 3))))
          (overlay-put foreign 'face 'italic)
          (setq vocab-language "german")
          (vocab-mode 1)
          (should (vocab--overlays))
          (vocab-mode -1)
          (should-not vocab-mode)
          (should-not (vocab--overlays))
          (should (equal (buffer-string) text))
          (should (eq (get-text-property (point-min) 'face) 'bold))
          (should (eq (get-text-property (point-min) 'my-property) 'kept))
          (should (memq foreign (overlays-in (point-min) (point-max))))
          (should (overlay-buffer foreign))
          ;; The language stays associated with the buffer.
          (should (equal vocab-language "german")))))))

(ert-deftest vocab-mode-test-clear-annotations ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund sieht den Hund."
      (vocab-clear-annotations)
      (should-not (vocab--overlays))
      (vocab-refresh-buffer)
      (should (= 5 (length (vocab--overlays)))))))

(ert-deftest vocab-mode-test-re-enabling-restores-state-from-database ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund sieht den Hund."
      (vocab-mode-test--goto-word "Hund")
      (vocab-mark-known)
      (vocab-mode -1)
      (vocab-mode 1)
      (should (equal (vocab-mode-test--statuses)
                     '(("Der" . unknown) ("Hund" . known) ("sieht" . unknown)
                       ("den" . unknown) ("Hund" . known)))))))

(ert-deftest vocab-mode-test-scanning-does-not-write-unknown-words ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund sieht den Hund."
      (should (= 0 (caar (sqlite-select (vocab-db-open)
                                        "SELECT count(*) FROM vocabulary")))))))

(ert-deftest vocab-mode-test-tolerates-buffer-changes ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund"
      (vocab-mode-test--goto-word "Hund")
      (vocab-mark-known)
      (goto-char (point-max))
      (insert " sieht den Hund.")
      (should (equal (vocab-mode-test--statuses)
                     '(("Der" . unknown) ("Hund" . known) ("sieht" . unknown)
                       ("den" . unknown) ("Hund" . known))))
      ;; Editing a word in place re-resolves it rather than leaving a stale
      ;; annotation behind.
      (vocab-mode-test--goto-word "sieht")
      (delete-char 5)
      (insert "Hund")
      (should (equal (vocab-mode-test--statuses)
                     '(("Der" . unknown) ("Hund" . known) ("Hund" . known)
                       ("den" . unknown) ("Hund" . known)))))))

;;;; Re-rendering major modes

(ert-deftest vocab-mode-test-registers-render-hook ()
  "Modes that re-render get a buffer-local hook, and lose it on disable."
  (vocab-mode-test--with-db
    (with-temp-buffer
      (eww-mode)
      (let ((inhibit-read-only t)) (insert "Der Hund."))
      (setq vocab-language "german")
      (vocab-mode 1)
      (should (eq vocab--render-hook 'eww-after-render-hook))
      (should (memq #'vocab--after-render eww-after-render-hook))
      (should (local-variable-p 'eww-after-render-hook))
      (vocab-mode -1)
      (should-not vocab--render-hook)
      (should-not (memq #'vocab--after-render eww-after-render-hook)))))

(ert-deftest vocab-mode-test-no-render-hook-in-ordinary-buffers ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund."
      (should-not vocab--render-hook)
      (should-not (local-variable-p 'eww-after-render-hook)))))

(ert-deftest vocab-mode-test-re-render-restores-annotations ()
  "A mode replacing the whole buffer must end up correctly annotated."
  (vocab-mode-test--with-db
    (with-temp-buffer
      (eww-mode)
      (let ((inhibit-read-only t))
        (insert "Der Hund sieht den Hund."))
      (goto-char (point-min))
      (setq vocab-language "german")
      (vocab-mode 1)
      (vocab-mode-test--goto-word "Hund")
      (vocab-mark-known)
      ;; Render another page into the same buffer, the way eww and nov do.
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Ein Hund und ein Baum."))
      (run-hooks 'eww-after-render-hook)
      (should (equal (vocab-mode-test--statuses)
                     '(("Ein" . unknown) ("Hund" . known) ("und" . unknown)
                       ("ein" . unknown) ("Baum" . unknown)))))))

(ert-deftest vocab-mode-test-re-render-picks-up-other-buffers-marks ()
  "Each render re-reads the database, so marks made elsewhere show up."
  (vocab-mode-test--with-db
    (with-temp-buffer
      (eww-mode)
      (let ((inhibit-read-only t)) (insert "Der Baum."))
      (setq vocab-language "german")
      (vocab-mode 1)
      (should (eq (vocab-status "baum") 'unknown))
      ;; Another buffer marks the word.
      (vocab-db-set-status "german" "baum" 'known)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Der Baum steht."))
      (run-hooks 'eww-after-render-hook)
      (should (eq (vocab-status "baum") 'known))
      (should (equal (vocab-mode-test--statuses)
                     '(("Der" . unknown) ("Baum" . known)
                       ("steht" . unknown)))))))

;;;; Cyrillic

(ert-deftest vocab-mode-test-russian ()
  (vocab-mode-test--with-db
    (with-temp-buffer
      (text-mode)
      (insert "Он медленно шёл домой. «Здравствуйте!» — сказал ЁЖИК.")
      (goto-char (point-min))
      (setq vocab-language "russian")
      (vocab-mode 1)
      (should (equal (mapcar #'car (vocab-mode-test--statuses))
                     '("Он" "медленно" "шёл" "домой" "Здравствуйте"
                       "сказал" "ЁЖИК")))
      (vocab-mode-test--goto-word "ЁЖИК")
      (vocab-mark-known)
      (should (eq (vocab-db-get-status "russian" "ёжик") 'known))
      (should (eq (vocab-status "Ёжик") 'known)))))

;;;; Persistence across buffers

(ert-deftest vocab-mode-test-persists-across-buffers ()
  (vocab-mode-test--with-db
    (let ((buffer (generate-new-buffer "*vocab-first*")))
      (with-current-buffer buffer
        (text-mode)
        (insert "Der Hund.")
        (setq vocab-language "german")
        (vocab-mode 1)
        (vocab-mode-test--goto-word "Hund")
        (vocab-mark-known))
      (kill-buffer buffer))
    ;; A brand new buffer, and a fresh database connection.
    (vocab-db-close-all)
    (vocab-mode-test--with-buffer "Ein Hund und ein Haus."
      (should (eq (vocab-status "hund") 'known))
      (should (eq (vocab-status "Hund") 'known))
      (should (eq (vocab-status "Haus") 'unknown))
      (should (equal (vocab-mode-test--statuses)
                     '(("Ein" . unknown) ("Hund" . known) ("und" . unknown)
                       ("ein" . unknown) ("Haus" . unknown)))))))

(ert-deftest vocab-mode-test-language-isolation ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Die Tür."
      (vocab-mode-test--goto-word "Die")
      (vocab-mark-known))
    (with-temp-buffer
      (text-mode)
      (insert "Die Tür.")
      (setq vocab-language "french")
      (vocab-mode 1)
      (goto-char (point-min))
      (should (eq (vocab-status "die") 'unknown))
      (should (equal (vocab-mode-test--statuses)
                     '(("Die" . unknown) ("Tür" . unknown)))))))

;;;; Read-only buffers

(ert-deftest vocab-mode-test-works-in-read-only-buffers ()
  (vocab-mode-test--with-db
    (let ((text "Der Hund sieht den Hund."))
      (with-temp-buffer
        (text-mode)
        (insert text)
        (goto-char (point-min))
        (setq vocab-language "german")
        (set-buffer-modified-p nil)
        (setq buffer-read-only t)
        (vocab-mode 1)
        (should (= 5 (length (vocab--overlays))))
        (vocab-mode-test--goto-word "Hund")
        (vocab-mark-learning)
        (should (eq (vocab-status "hund") 'learning))
        (vocab-mark-known)
        (should (eq (vocab-status "hund") 'known))
        (vocab-mark-unknown)
        (should (eq (vocab-status "hund") 'unknown))
        (vocab-next-unknown)
        (should buffer-read-only)
        (should (equal (buffer-string) text))
        (should-not (buffer-modified-p))))))

;;;; Navigation

(ert-deftest vocab-mode-test-navigation-forward-and-backward ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund sieht den Hund."
      (goto-char (point-min))
      (vocab-next-unknown)
      (should (equal (vocab-word-at-point) "Hund"))
      (vocab-next-unknown)
      (should (equal (vocab-word-at-point) "sieht"))
      (vocab-previous-unknown)
      (should (equal (vocab-word-at-point) "Hund"))
      (vocab-previous-unknown)
      (should (equal (vocab-word-at-point) "Der")))))

(ert-deftest vocab-mode-test-navigation-skips-known-and-learning ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund sieht den Baum."
      (vocab-mode-test--goto-word "Hund")
      (vocab-mark-known)
      (vocab-mode-test--goto-word "sieht")
      (vocab-mark-learning)
      (vocab-mode-test--goto-word "den")
      (vocab-mark-known)
      (goto-char (point-min))
      (vocab-next-unknown)
      (should (equal (vocab-word-at-point) "Baum"))
      (vocab-previous-unknown)
      (should (equal (vocab-word-at-point) "Der")))))

(ert-deftest vocab-mode-test-navigation-wraps-around ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund sieht den Baum."
      (vocab-mode-test--goto-word "Baum")
      (vocab-next-unknown)
      (should (equal (vocab-word-at-point) "Der"))
      (vocab-previous-unknown)
      (should (equal (vocab-word-at-point) "Baum")))))

(ert-deftest vocab-mode-test-navigation-without-unknown-words ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund."
      (vocab-mode-test--goto-word "Der")
      (vocab-mark-known)
      (vocab-mode-test--goto-word "Hund")
      (vocab-mark-learning)
      (let ((start (point)))
        (should (equal (vocab-mode-test--message-of #'vocab-next-unknown) "No unknown words"))
        (should (= (point) start))
        (should (equal (vocab-mode-test--message-of #'vocab-previous-unknown)
                       "No unknown words"))
        (should (= (point) start))))))

;;;; Keymap

(ert-deftest vocab-mode-test-no-keys-bound-by-default ()
  (should-not (keymap-lookup vocab-mode-map "n"))
  (should-not (keymap-lookup vocab-mode-map "RET"))
  (should (keymapp vocab-mode-map)))

(ert-deftest vocab-mode-test-reading-keys-are-read-only-buffer-local ()
  "Opt-in reading keys must never shadow self-insertion."
  (vocab-mode-test--with-db
    (unwind-protect
        (progn
          (vocab-mode-bind-reading-keys)
          (vocab-mode-test--with-buffer "Der Hund."
            ;; Editable: every key keeps doing what it always did.
            (should (eq (key-binding (kbd "n")) #'self-insert-command))
            (should (eq (key-binding (kbd "k")) #'self-insert-command))
            (should (eq (key-binding (kbd "u")) #'self-insert-command))
            (setq buffer-read-only t)
            ;; Read-only: the reading workflow takes over.
            (should (eq (key-binding (kbd "n")) #'vocab-next-unknown))
            (should (eq (key-binding (kbd "p")) #'vocab-previous-unknown))
            (should (eq (key-binding (kbd "k")) #'vocab-mark-known))
            (should (eq (key-binding (kbd "l")) #'vocab-mark-learning))
            (should (eq (key-binding (kbd "u")) #'vocab-mark-unknown))
            (should (eq (key-binding (kbd "RET")) #'vocab-show-word))
            ;; And only while the mode is on.
            (vocab-mode -1)
            (should-not (eq (key-binding (kbd "n")) #'vocab-next-unknown))))
      (setcdr vocab-mode-map nil))))

(ert-deftest vocab-mode-test-reading-keys-accept-another-keymap ()
  (let ((map (make-sparse-keymap)))
    (should (eq (vocab-mode-bind-reading-keys map) map))
    (with-temp-buffer
      ;; Key lookup itself applies the filter, so the binding resolves to
      ;; the command only in a read-only buffer.
      (should-not (keymap-lookup map "n"))
      (setq buffer-read-only t)
      (should (eq (keymap-lookup map "n") #'vocab-next-unknown)))
    ;; `vocab-mode-map' itself is left alone.
    (should-not (cdr vocab-mode-map))))

;;;; Narrowing

(ert-deftest vocab-mode-test-respects-narrowing ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Aussen Anfang Mitte Ende Aussen"
      (vocab-mode -1)
      (goto-char (point-min))
      (search-forward "Anfang")
      (narrow-to-region (match-beginning 0)
                        (progn (search-forward "Ende") (point)))
      (vocab-mode 1)
      (should (equal (vocab-mode-test--statuses)
                     '(("Anfang" . unknown) ("Mitte" . unknown)
                       ("Ende" . unknown))))
      (save-restriction
        (widen)
        (should (= 3 (length (vocab--overlays)))))
      ;; Navigation stays inside the accessible portion.
      (goto-char (point-max))
      (vocab-next-unknown)
      (should (equal (vocab-word-at-point) "Anfang"))
      (goto-char (point-min))
      (vocab-previous-unknown)
      (should (equal (vocab-word-at-point) "Ende"))
      ;; Widening again and refreshing picks up the rest of the buffer.
      (widen)
      (vocab-refresh-buffer)
      (should (= 5 (length (vocab--overlays)))))))

;;;; Translation

(ert-deftest vocab-mode-test-translate-requires-a-backend ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund."
      (let ((vocab-translate-function nil))
        (should-error (vocab-translate-word) :type 'user-error)))))

(ert-deftest vocab-mode-test-translate-requires-a-word ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund.   "
      (let ((vocab-translate-function (lambda (_w _l cb) (funcall cb "dog"))))
        (goto-char (point-max))
        (should-error (vocab-translate-word) :type 'user-error)))))

(ert-deftest vocab-mode-test-translate-passes-word-and-language ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund."
      (let* (seen
             (vocab-translate-function
              (lambda (word language callback)
                (setq seen (list word language))
                (funcall callback (format "%s: dog" word))))
             (vocab--translation-cache (make-hash-table :test #'equal)))
        (vocab-mode-test--goto-word "Hund")
        ;; The answer already opens with the word, so it is shown as is.
        (should (equal (vocab-mode-test--message-of #'vocab-translate-word)
                       "Hund: dog"))
        ;; The surface form is handed over, not the normalized key.
        (should (equal seen '("Hund" "german")))))))

(ert-deftest vocab-mode-test-translate-is-asynchronous ()
  "A backend may answer long after the command returned."
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund."
      (let* (pending
             (vocab-translate-function
              (lambda (_word _language callback) (setq pending callback)))
             (vocab--translation-cache (make-hash-table :test #'equal)))
        (vocab-mode-test--goto-word "Hund")
        (should (equal (vocab-mode-test--message-of #'vocab-translate-word)
                       "Translating Hund..."))
        (should (functionp pending))
        ;; The answer arrives later and is displayed then.
        (should (equal (vocab-mode-test--message-of
                        (lambda () (funcall pending "dog")))
                       "Hund — dog"))))))

(ert-deftest vocab-mode-test-translate-handles-no-answer ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund."
      (let ((vocab-translate-function (lambda (_w _l cb) (funcall cb nil)))
            (vocab--translation-cache (make-hash-table :test #'equal)))
        (vocab-mode-test--goto-word "Hund")
        (should (equal (vocab-mode-test--message-of #'vocab-translate-word)
                       "No translation for Hund"))
        (should (equal (vocab-mode-test--message-of #'vocab-translate-word)
                       "No translation for Hund"))))))

(ert-deftest vocab-mode-test-translate-caches-and-refreshes ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund und der HUND."
      (let* ((calls 0)
             (vocab-translate-function
              (lambda (_word _language callback)
                (setq calls (1+ calls))
                (funcall callback (format "dog #%d" calls))))
             (vocab--translation-cache (make-hash-table :test #'equal)))
        (vocab-mode-test--goto-word "Hund")
        (should (equal (vocab-mode-test--message-of #'vocab-translate-word)
                       "Hund — dog #1"))
        ;; Asking again reuses the answer rather than paying for it twice.
        (should (equal (vocab-mode-test--message-of #'vocab-translate-word)
                       "Hund — dog #1"))
        (should (= calls 1))
        ;; A differently cased occurrence shares the cache entry.
        (vocab-mode-test--goto-word "HUND")
        (should (equal (vocab-mode-test--message-of #'vocab-translate-word)
                       "HUND — dog #1"))
        (should (= calls 1))
        ;; A prefix argument asks again.
        (should (equal (vocab-mode-test--message-of
                        (lambda () (vocab-translate-word t)))
                       "HUND — dog #2"))
        (should (= calls 2))
        (vocab-clear-translation-cache)
        (should (= 0 (hash-table-count vocab--translation-cache)))))))

(ert-deftest vocab-mode-test-translate-does-not-echo-the-word-twice ()
  "Backends that open with the word themselves must not be prefixed again."
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund."
      (let ((vocab--translation-cache (make-hash-table :test #'equal)))
        (vocab-mode-test--goto-word "Hund")
        (let ((vocab-translate-function
               (lambda (_w _l cb) (funcall cb "Hund — dog, hound"))))
          (should (equal (vocab-mode-test--message-of #'vocab-translate-word)
                         "Hund — dog, hound")))
        (clrhash vocab--translation-cache)
        (let ((vocab-translate-function
               (lambda (_w _l cb) (funcall cb "hund: dog"))))
          (should (equal (vocab-mode-test--message-of #'vocab-translate-word)
                         "hund: dog")))
        (clrhash vocab--translation-cache)
        (let ((vocab-translate-function
               (lambda (_w _l cb) (funcall cb "dog, hound"))))
          (should (equal (vocab-mode-test--message-of #'vocab-translate-word)
                         "Hund — dog, hound")))))))

(ert-deftest vocab-mode-test-translate-is-language-specific ()
  (vocab-mode-test--with-db
    (let ((vocab--translation-cache (make-hash-table :test #'equal))
          (vocab-translate-function
           (lambda (word language callback)
             (funcall callback (format "%s in %s" word language)))))
      (vocab-mode-test--with-buffer "Die Tür."
        (vocab-mode-test--goto-word "Die")
        (should (equal (vocab-mode-test--message-of #'vocab-translate-word)
                       "Die in german")))
      (with-temp-buffer
        (text-mode)
        (insert "Die Tür.")
        (setq vocab-language "french")
        (vocab-mode 1)
        (vocab-mode-test--goto-word "Die")
        (should (equal (vocab-mode-test--message-of #'vocab-translate-word)
                       "Die in french"))))))

;;;; Commands and errors

(ert-deftest vocab-mode-test-show-word ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der langsam."
      (vocab-mode-test--goto-word "langsam")
      (should (equal (vocab-mode-test--message-of #'vocab-show-word) "langsam — unknown"))
      (vocab-mark-learning)
      (should (equal (vocab-mode-test--message-of #'vocab-show-word) "langsam — learning"))
      (goto-char (point-max))
      (should (equal (vocab-mode-test--message-of #'vocab-show-word) "No word at point")))))

(ert-deftest vocab-mode-test-marking-without-word-at-point ()
  (vocab-mode-test--with-db
    (vocab-mode-test--with-buffer "Der Hund.   "
      (goto-char (point-max))
      (should-error (vocab-mark-known) :type 'user-error)
      (should-error (vocab-mark-learning) :type 'user-error)
      (should-error (vocab-mark-unknown) :type 'user-error))))

(ert-deftest vocab-mode-test-commands-require-enabled-mode ()
  (with-temp-buffer
    (insert "Der Hund.")
    (goto-char (point-min))
    (should-error (vocab-mark-known) :type 'user-error)
    (should-error (vocab-next-unknown) :type 'user-error)
    (should-error (vocab-refresh-buffer) :type 'user-error)))

(ert-deftest vocab-mode-test-enabling-fails-cleanly-without-sqlite ()
  (vocab-mode-test--with-db
    (with-temp-buffer
      (text-mode)
      (insert "Der Hund.")
      (setq vocab-language "german")
      (cl-letf (((symbol-function 'vocab-db-available-p) (lambda () nil)))
        (should-error (vocab-mode 1) :type 'user-error))
      (should-not vocab-mode)
      (should-not (vocab--overlays))
      (should (equal (buffer-string) "Der Hund.")))))

(provide 'vocab-mode-test)
;;; vocab-mode-test.el ends here
