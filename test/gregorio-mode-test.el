;;; gregorio-mode-test.el --- Tests for gregorio-mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 AISCGre Brasil
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; ERT tests for the GABC editing commands and syntax highlighting.
;; Run with: make test

;;; Code:

(require 'ert)
(require 'gregorio-mode)

(defmacro gregorio-test-with-buffer (text &rest body)
  "Run BODY in a `gregorio-mode' buffer containing TEXT."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((gregorio-lsp-client nil))
       (insert ,text)
       (gregorio-mode)
       (goto-char (point-min))
       ,@body)))

(defun gregorio-test-body ()
  "Return the buffer text after the `%%' line."
  (buffer-substring-no-properties (gregorio--body-start) (point-max)))

(defun gregorio-test-face-at (string &optional nth)
  "Return the face at the NTH (default 0) occurrence of STRING."
  (save-excursion
    (goto-char (point-min))
    (dotimes (_ (1+ (or nth 0)))
      (search-forward string))
    (get-text-property (match-beginning 0) 'face)))

;;; Structure

(ert-deftest gregorio-test-nabc-lines ()
  (gregorio-test-with-buffer "name: x;\nnabc-lines: 2;\n%%\n(c4) a(f)"
    (should (= (gregorio-nabc-lines) 2)))
  (gregorio-test-with-buffer "name: x;\n%%\nnabc-lines: 3;\n(c4)"
    (should (= (gregorio-nabc-lines) 0))))

(ert-deftest gregorio-test-context ()
  (gregorio-test-with-buffer
      "nabc-lines: 1;\n%%\n(c4) Ky(f|vi[x]) % c\n"
    (should (eq (gregorio--context 3) 'header))
    (should (eq (gregorio--context (progn (search-forward "Ky") (point)))
                'lyric))
    (should (eq (gregorio--context (progn (search-forward "(") (point)))
                'gabc))
    (should (eq (gregorio--context (progn (search-forward "v") (point)))
                'nabc))
    (should (eq (gregorio--context (progn (search-forward "c") (point)))
                'comment))))

;;; Note shifting

(ert-deftest gregorio-test-shift-pitch ()
  (should (eq (gregorio-shift-pitch ?a 1) ?b))
  (should (eq (gregorio-shift-pitch ?n 1) ?p))
  (should (eq (gregorio-shift-pitch ?p 1) ?a))
  (should (eq (gregorio-shift-pitch ?a -1) ?p))
  (should (eq (gregorio-shift-pitch ?G 1) ?H))
  (should (eq (gregorio-shift-pitch ?o 1) ?o))
  (should (eq (gregorio-shift-pitch ?f 3) ?i)))

(ert-deftest gregorio-test-shift-up-body ()
  (gregorio-test-with-buffer "name: abc;\n%%\n(c4) Ky(f)ri(gh)e(hgf) (::)"
    (gregorio-shift-notes 1)
    (should (equal (buffer-string)
                   "name: abc;\n%%\n(c4) Ky(g)ri(hi)e(ihg) (::)"))))

(ert-deftest gregorio-test-shift-down-body ()
  (gregorio-test-with-buffer "%%\n(c4) a(a)b(P)"
    (gregorio-shift-notes -1)
    (should (equal (gregorio-test-body) "(c4) a(p)b(N)"))))

(ert-deftest gregorio-test-shift-preserves-modifiers ()
  (gregorio-test-with-buffer
      "%%\n(c4) a(gx) b(f+) c(eo'_) d(fv[nv:\\hb]) e(f@[gh])"
    (gregorio-shift-notes 1)
    (should (equal (gregorio-test-body)
                   "(c4) a(hx) b(g+) c(fo'_) d(gv[nv:\\hb]) e(g@[hi])"))))

(ert-deftest gregorio-test-shift-skips-comments-and-clefs ()
  (gregorio-test-with-buffer "%%\n(cb3) a(f) % (f)\n(f3)"
    (gregorio-shift-notes 1)
    (should (equal (gregorio-test-body) "(cb3) a(g) % (f)\n(f3)"))))

(ert-deftest gregorio-test-shift-nabc-lines ()
  (gregorio-test-with-buffer
      "nabc-lines: 2;\n%%\n(c4) a(fg|vi|pe|hi|ta|cl)"
    (gregorio-shift-notes 1)
    (should (equal (gregorio-test-body) "(c4) a(gh|vi|pe|ij|ta|cl)"))))

(ert-deftest gregorio-test-shift-nabc-without-header ()
  (gregorio-test-with-buffer "%%\n(c4) a(f|vi|g)"
    (gregorio-shift-notes 1)
    (should (equal (gregorio-test-body) "(c4) a(g|vi|g)"))))

(ert-deftest gregorio-test-shift-region ()
  (gregorio-test-with-buffer "%%\n(c4) a(f) b(g) c(h)"
    (let ((beg (progn (search-forward "b(") (point)))
          (end (progn (search-forward ")") (point))))
      (gregorio-shift-notes 1 beg end))
    (should (equal (gregorio-test-body) "(c4) a(f) b(h) c(h)"))))

(ert-deftest gregorio-test-shift-ignores-header ()
  (gregorio-test-with-buffer "name: (abc);\n%%\n(c4) a(f)"
    (gregorio-shift-notes 1 (point-min) (point-max))
    (should (equal (buffer-string) "name: (abc);\n%%\n(c4) a(g)"))))

(ert-deftest gregorio-test-shift-requires-separator ()
  (gregorio-test-with-buffer "(c4) a(f)"
    (should-error (gregorio-shift-notes 1) :type 'user-error)))

(ert-deftest gregorio-test-shift-skips-verbatim-lyrics ()
  (gregorio-test-with-buffer "%%\n(c4) <v>(</v>a(f)"
    (gregorio-shift-notes 1)
    (should (equal (gregorio-test-body) "(c4) <v>(</v>a(g)"))))

;;; Fill parens

(ert-deftest gregorio-test-fill-parens ()
  (gregorio-test-with-buffer "%%\n(fgh) () ( ) () (ij) () ()"
    (should (= (gregorio-fill-parens) 5))
    (should (equal (gregorio-test-body) "(fgh) (h) (h) (h) (ij) (j) (j)"))))

(ert-deftest gregorio-test-fill-parens-across-lines-and-clefs ()
  (gregorio-test-with-buffer "%%\n(c4) a(fg)\n(c3) b() c(::) d()"
    (gregorio-fill-parens)
    (should (equal (gregorio-test-body)
                   "(c4) a(fg)\n(c3) b(g) c(::) d(g)"))))

(ert-deftest gregorio-test-fill-parens-no-seed ()
  (gregorio-test-with-buffer "%%\n(c4) a() b(f)"
    (gregorio-fill-parens)
    (should (equal (gregorio-test-body) "(c4) a() b(f)"))))

(ert-deftest gregorio-test-fill-parens-nabc ()
  (gregorio-test-with-buffer "nabc-lines: 1;\n%%\n(c4) a(fg|hk) b()"
    (gregorio-fill-parens)
    (should (equal (gregorio-test-body) "(c4) a(fg|hk) b(g)"))))

(ert-deftest gregorio-test-fill-parens-region ()
  (gregorio-test-with-buffer "%%\n(f) a() b() c()"
    (let ((beg (progn (search-forward "b") (point)))
          (end (progn (search-forward ")") (point))))
      (gregorio-fill-parens beg end))
    (should (equal (gregorio-test-body) "(f) a() b(f) c()"))))

;;; Ligatures

(ert-deftest gregorio-test-ligatures-roundtrip ()
  (gregorio-test-with-buffer "name: æ;\n%%\nCæ(f)lum ǽ(g) cœ(h)"
    (should (= (gregorio-convert-ligatures-to-tags) 3))
    (should (equal (buffer-string)
                   "name: æ;\n%%\nC<sp>ae</sp>(f)lum <sp>'ae</sp>(g) c<sp>oe</sp>(h)"))
    (should (= (gregorio-convert-tags-to-ligatures) 3))
    (should (equal (buffer-string) "name: æ;\n%%\nCæ(f)lum ǽ(g) cœ(h)"))))

;;; Font lock

(ert-deftest gregorio-test-font-lock ()
  (gregorio-test-with-buffer
      (concat "name: Kyrie;\nmode: 8;\nnabc-lines: 1;\n%%\n"
              "(c4) <b>Ky</b>(f.|vi) ri(gx|pe) e(::) % note\n")
    (font-lock-ensure)
    (should (eq (gregorio-test-face-at "name") 'gregorio-header-name-face))
    (should (eq (gregorio-test-face-at "Kyrie") 'gregorio-header-value-face))
    (should (eq (gregorio-test-face-at "8") 'gregorio-number-face))
    (should (eq (gregorio-test-face-at "%%") 'gregorio-separator-face))
    (should (eq (gregorio-test-face-at "c4") 'gregorio-clef-face))
    (should (memq 'gregorio-bold-face
                  (ensure-list (gregorio-test-face-at "Ky</b>"))))
    (should (eq (gregorio-test-face-at "f.") 'gregorio-pitch-face))
    (should (eq (gregorio-test-face-at ".|") 'gregorio-rhythm-face))
    (should (eq (gregorio-test-face-at "vi") 'gregorio-nabc-neume-face))
    (should (eq (gregorio-test-face-at "x|") 'gregorio-alteration-face))
    (should (eq (gregorio-test-face-at "::") 'gregorio-bar-face))
    (should (eq (gregorio-test-face-at "% note") 'font-lock-comment-delimiter-face))))

(ert-deftest gregorio-test-font-lock-nabc-alternation ()
  ;; With nabc-lines: 1, the third segment is GABC again.
  (gregorio-test-with-buffer "nabc-lines: 1;\n%%\n(c4) a(f|pe|g)\n"
    (font-lock-ensure)
    (should (eq (gregorio-test-face-at "pe") 'gregorio-nabc-neume-face))
    (should (eq (gregorio-test-face-at "g)") 'gregorio-pitch-face))))

(provide 'gregorio-mode-test)

;;; gregorio-mode-test.el ends here
