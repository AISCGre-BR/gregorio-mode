;;; gregorio-preview-test.el --- Tests for gregorio-preview -*- lexical-binding: t; -*-

;; Copyright (C) 2026 AISCGre Brasil
;; SPDX-License-Identifier: MIT

;;; Commentary:

;; ERT tests for the inline score previews.  The integration tests are
;; skipped unless gregorio, LuaLaTeX and pdftocairo are installed.
;; Run with: make test

;;; Code:

(require 'ert)
(require 'gregorio-preview)

(defconst gregorio-preview-test-directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Directory of this test file.")

(defmacro gregorio-preview-test-with-buffer (text &rest body)
  "Run BODY in a `gregorio-mode' buffer containing TEXT."
  (declare (indent 1))
  `(with-temp-buffer
     (let ((gregorio-lsp-client nil))
       (insert ,text)
       (gregorio-mode)
       (goto-char (point-min))
       ,@body)))

(defconst gregorio-preview-test-text
  "name: Test;
annotation: INT.;
%%
(c4) A(f)ve(g) (,)

% a comment
Ma(h)ri(g)a(f) (;)
(f3) gra(f)ti(g)a(h) (:)
ple(g)na.(f) (::)
"
  "Sample chant used by the chunk tests.")

;;; Chunks

(ert-deftest gregorio-preview-test-chunks-skip-blank-and-comments ()
  (gregorio-preview-test-with-buffer gregorio-preview-test-text
    (let ((chunks (gregorio-preview--chunks)))
      (should (= (length chunks) 4))
      (should (equal (mapcar (lambda (c)
                               (buffer-substring-no-properties (nth 0 c)
                                                               (nth 1 c)))
                             chunks)
                     '("(c4) A(f)ve(g) (,)"
                       "Ma(h)ri(g)a(f) (;)"
                       "(f3) gra(f)ti(g)a(h) (:)"
                       "ple(g)na.(f) (::)"))))))

(ert-deftest gregorio-preview-test-chunks-carry-clef ()
  (gregorio-preview-test-with-buffer gregorio-preview-test-text
    (let ((gabc (mapcar (lambda (c) (nth 2 c)) (gregorio-preview--chunks))))
      ;; The first line already starts with its clef.
      (should (string-suffix-p "%%\n(c4) A(f)ve(g) (,)\n" (nth 0 gabc)))
      (should (string-suffix-p "%%\n(c4) Ma(h)ri(g)a(f) (;)\n" (nth 1 gabc)))
      (should (string-suffix-p "%%\n(f3) gra(f)ti(g)a(h) (:)\n" (nth 2 gabc)))
      ;; Clef changes carry over to the following lines.
      (should (string-suffix-p "%%\n(f3) ple(g)na.(f) (::)\n" (nth 3 gabc))))))

(ert-deftest gregorio-preview-test-chunks-second-clef ()
  (gregorio-preview-test-with-buffer "%%\n(c4@cb2) A(f)\nB(g)\n"
    (should (string-suffix-p "%%\n(c4@cb2) B(g)\n"
                             (nth 2 (nth 1 (gregorio-preview--chunks)))))))

(ert-deftest gregorio-preview-test-chunks-header ()
  (gregorio-preview-test-with-buffer gregorio-preview-test-text
    (let ((chunks (gregorio-preview--chunks)))
      (should (nth 3 (nth 0 chunks)))
      (should-not (nth 3 (nth 1 chunks)))
      (should (string-prefix-p "name: Test;\nannotation: INT.;\n%%\n"
                               (nth 2 (nth 0 chunks))))
      (should (string-prefix-p "name: Test;\n%%\n" (nth 2 (nth 1 chunks)))))))

(ert-deftest gregorio-preview-test-chunks-region ()
  (gregorio-preview-test-with-buffer gregorio-preview-test-text
    (search-forward "Ma(h)")
    (let ((chunks (gregorio-preview--chunks (point) (line-end-position))))
      (should (= (length chunks) 1))
      (should-not (nth 3 (car chunks))))
    ;; A range covering the header only yields body lines.
    (should (= (length (gregorio-preview--chunks (point-min) (point-max))) 4))))

(ert-deftest gregorio-preview-test-chunks-require-body ()
  (gregorio-preview-test-with-buffer "name: x;\n"
    (should-error (gregorio-preview--chunks) :type 'user-error)))

;;; LaTeX document and cache key

(ert-deftest gregorio-preview-test-latex-document ()
  (let ((tex (gregorio-preview--latex-document
              '(("chunk-1.gtex" . t) ("chunk-2.gtex" . nil))
              '(:width "300pt" :color "FFFFFF"
                :preamble "\\grechangestaffsize{15}"))))
    (should (string-prefix-p
             "\\PassOptionsToPackage{active,tightpage,auctex}{preview}\n\\documentclass{article}"
             tex))
    (should (string-match-p "\\\\usepackage{gregoriotex}" tex))
    (should (string-match-p "\\\\usepackage{preview}" tex))
    (should (string-match-p
             "\\\\begin{document}\n\\\\setlength{\\\\textwidth}{300pt}" tex))
    (should (string-match-p "\\\\color\\[HTML\\]{FFFFFF}" tex))
    (should (string-match-p "\\\\grechangestaffsize{15}\n\\\\begin{document}" tex))
    (should (string-match-p
             "\\\\gresetinitiallines{1}\\\\gregorioscore\\[n\\]{chunk-1.gtex}"
             tex))
    (should (string-match-p
             "\\\\gresetinitiallines{0}\\\\gregorioscore\\[n\\]{chunk-2.gtex}"
             tex))))

(ert-deftest gregorio-preview-test-latex-document-master ()
  (let ((tex (gregorio-preview--latex-document
              '(("chunk-1.gtex" . t))
              '(:width "1pt" :preamble "\\usepackage{x}"
                :master-preamble "\\documentclass{book}\n\\usepackage{tikz}\n"
                :master-setup "\\grechangestaffsize{15}"))))
    (should-not (string-match-p "{article}" tex))
    (should (string-match-p
             "{preview}\n\\\\documentclass{book}\n\\\\usepackage{tikz}" tex))
    ;; The master preamble comes before the local preamble.
    (should (< (string-match "tikz" tex) (string-match "{x}" tex)))
    ;; Setup commands of the master body come right after \begin{document}.
    (should (string-match-p
             "\\\\begin{document}\n\\\\grechangestaffsize{15}\n\\\\setlength"
             tex))))

(ert-deftest gregorio-preview-test-latex-document-without-color ()
  (should-not (string-match-p
               "\\\\color\\["
               (gregorio-preview--latex-document
                '(("chunk-1.gtex" . t)) '(:width "1pt" :preamble "")))))

;;; LaTeX log

(defconst gregorio-preview-test-log
  "This is LuaHBTeX
./preview.tex:3: Preview: Snippet 1 started.
./preview.tex:3: Preview: Snippet 1 ended.(1+2x3).
./preview.tex:4: Preview: Snippet 2 started.
./chunk-2.gtex:18: Undefined control sequence.
\\gre@nextmiddlesyllablepart ->\\tikzmarknode 
                                            {x}{B}
l.18 }
./chunk-2.gtex:26: Undefined control sequence.
\\gre@middlesyllablepart ->\\tikzmarknode 
                                        {x}{B}
./chunk-2.gtex:30: Missing $ inserted.
./preview.tex:4: Preview: Snippet 2 ended.(1+2x3).
./preview.tex:5: Preview: Snippet 3 started.
./preview.tex:5: Preview: Snippet 3 ended.(1+2x3).
Output written on preview.pdf (3 pages, 1234 bytes).
"
  "Excerpt of a LaTeX log with an error in the second snippet.")

(ert-deftest gregorio-preview-test-parse-log ()
  (let ((parsed (gregorio-preview--parse-log gregorio-preview-test-log)))
    (should (= (plist-get parsed :pages) 3))
    (should-not (plist-get parsed :global))
    (should-not (gregorio-preview--snippet-error parsed 1))
    (should (equal (gregorio-preview--snippet-error parsed 2)
                   "Undefined control sequence \\tikzmarknode; Missing $ inserted."))
    (should-not (gregorio-preview--snippet-error parsed 3))
    ;; A snippet that never started.
    (should (equal (gregorio-preview--snippet-error parsed 4)
                   "LaTeX stopped before this line"))))

(ert-deftest gregorio-preview-test-parse-log-fatal ()
  (let ((parsed (gregorio-preview--parse-log
                 "! LaTeX Error: File `nothere.sty' not found.
! Emergency stop.
No pages of output.
")))
    (should (= (plist-get parsed :pages) 0))
    (should (equal (gregorio-preview--snippet-error parsed 1)
                   "LaTeX Error: File `nothere.sty' not found.; Emergency stop."))))

;;; Master document

(defmacro gregorio-preview-test-with-project (&rest body)
  "Run BODY in a temporary project with a master document.
The variable `dir' is bound to the project directory; the project has
main.tex, which includes scores/hymn.gabc, and an unrelated other.tex."
  (declare (indent 0))
  `(let ((dir (file-name-as-directory (make-temp-file "gregorio-test-" t))))
     (unwind-protect
         (progn
           (make-directory (expand-file-name "scores" dir))
           (with-temp-file (expand-file-name "other.tex" dir)
             (insert "\\documentclass{article}\n\\begin{document}\n"
                     "\\gregorioscore{scores/other}\n\\end{document}\n"))
           (with-temp-file (expand-file-name "main.tex" dir)
             (insert "\\documentclass{book}\n"
                     "% \\begin{document} in a comment\n"
                     "\\usepackage{tikz}\n\\usetikzlibrary{tikzmark}\n"
                     "\\usepackage{gregoriotex}\n"
                     "\\begin{document}\n"
                     "\\grechangestaffsize{15}\n"
                     "% \\gresetlinecolor{red}\n"
                     "\\gresetinitiallines{1}\n"
                     "\\grechangestyle{initial}{\\fontsize{40}{40}%\n"
                     "  \\selectfont}\n"
                     "% \\gregorioscore{scores/hymn}\n"
                     "\\gregorioscore[a]{scores/hymn}\n"
                     "\\grechangedim{spaceabovelines}{1cm}{scalable}\n"
                     "\\end{document}\n"))
           (with-temp-file (expand-file-name "scores/hymn.gabc" dir)
             (insert "name: Hymn;\n%%\n(c4) A(f) <v>\\tikzmarknode{x}{B}</v>(g) (::)\n"))
           ,@body)
       (delete-directory dir t))))

(ert-deftest gregorio-preview-test-find-master ()
  (gregorio-preview-test-with-project
    (should (equal (gregorio-preview--find-master
                    (expand-file-name "scores/hymn.gabc" dir))
                   (cons (expand-file-name "main.tex" dir)
                         (expand-file-name "main.tex" dir))))
    ;; A score that no file includes falls back to the main document.
    (should (equal (gregorio-preview--find-master
                    (expand-file-name "scores/unknown.gabc" dir))
                   (list (expand-file-name "main.tex" dir))))
    (let ((gregorio-preview-master-search-depth 0))
      (should-not (gregorio-preview--find-master
                   (expand-file-name "scores/hymn.gabc" dir))))))

(ert-deftest gregorio-preview-test-master-file-option ()
  (gregorio-preview-test-with-project
    (let ((buffer-file-name (expand-file-name "scores/hymn.gabc" dir))
          (default-directory (expand-file-name "scores/" dir)))
      (let ((gregorio-preview-master nil))
        (should (equal (gregorio-preview--master-file)
                       (expand-file-name "main.tex" dir))))
      (let ((gregorio-preview-master 'none))
        (should-not (gregorio-preview--master-file)))
      (let ((gregorio-preview-master "../other.tex"))
        (should (equal (gregorio-preview--master-file)
                       (expand-file-name "other.tex" dir))))
      (let ((gregorio-preview-master "missing.tex"))
        (should-error (gregorio-preview--master-file) :type 'user-error)))))

(ert-deftest gregorio-preview-test-master-preamble ()
  (gregorio-preview-test-with-project
    (let ((preamble (gregorio-preview--master-preamble
                     (expand-file-name "main.tex" dir) "hymn")))
      (should (equal (car preamble)
                     (concat "\\documentclass{book}\n"
                             "% \\begin{document} in a comment\n"
                             "\\usepackage{tikz}\n\\usetikzlibrary{tikzmark}\n"
                             "\\usepackage{gregoriotex}\n")))
      ;; Setup commands before the score, with multi-line arguments;
      ;; comments, \gresetinitiallines and later commands are left out.
      (should (equal (cdr preamble)
                     (concat "\\grechangestaffsize{15}\n"
                             "\\grechangestyle{initial}{\\fontsize{40}{40}%\n"
                             "  \\selectfont}"))))
    ;; Without a reference to the score, the whole body is searched.
    (should (string-suffix-p
             "\\grechangedim{spaceabovelines}{1cm}{scalable}"
             (cdr (gregorio-preview--master-preamble
                   (expand-file-name "main.tex" dir) "unknown"))))))

(defmacro gregorio-preview-test-with-book (&rest body)
  "Run BODY in a temporary Git project laid out like a LaTeX book.
The variable `dir' is bound to the project directory.  main.tex loads
preamble.sty (tikz, tikzmark and a Lua file read from a path relative
to the project root) and includes source/index.tex, a subfile, which
inputs source/partituras/hymn.tex.  That fragment declares its TeX root
and includes source/gabc/hymn.gabc through a custom macro."
  (declare (indent 0))
  `(let ((dir (file-name-as-directory (make-temp-file "gregorio-book-" t))))
     (unwind-protect
         (cl-flet ((write (file &rest text)
                     (let ((path (expand-file-name file dir)))
                       (make-directory (file-name-directory path) t)
                       (with-temp-file path (apply #'insert text)))))
           (call-process "git" nil nil nil "init" "-q" dir)
           (write "main.tex"
                  "\\documentclass{article}\n\\usepackage{preamble}\n"
                  "\\begin{document}\n\\subfile{source/index}\n\\end{document}\n")
           (write "preamble.sty"
                  "\\RequirePackage{tikz}\n\\usetikzlibrary{tikzmark}\n"
                  "\\RequirePackage{gregoriotex}\n"
                  "\\directlua{dofile(\"lib/setup.lua\")}\n"
                  "\\newcommand{\\BookScore}[1]{\\gregorioscore{#1}}\n")
           (write "lib/setup.lua" "token.set_macro(\"BookWord\", \"ok\")\n")
           (write "source/index.tex"
                  "\\documentclass[../main.tex]{subfiles}\n\\begin{document}\n"
                  "\\input{source/partituras/hymn}\n\\end{document}\n")
           (write "source/partituras/hymn.tex"
                  "%! TeX root = ../../main.tex\n"
                  "\\grechangestaffsize{15}\n"
                  "\\BookScore{gabc/hymn}\n"
                  "\\grechangestaffsize{20}\n")
           (write "source/partituras/other.tex"
                  "% -*- TeX-master: \"../../main\" -*-\n"
                  "%%% Local Variables:\n%%% TeX-master: \"../../main\"\n"
                  "%%% End:\n")
           (write "source/gabc/template.tex"
                  "\\documentclass{standalone}\n\\begin{document}\n"
                  "\\gregorioscore{{{SCORE}}.gabc}\n\\end{document}\n")
           (write "source/gabc/hymn.gabc"
                  "name: Hymn;\n%%\n"
                  "(c4) A(f) <v>\\tikzmarknode{x}{\\BookWord}</v>(g) (::)\n")
           (write "source/gabc/orphan.gabc" "%%\n(c4) A(f)\n")
           ,@body)
       (delete-directory dir t))))

(defun gregorio-preview-test-book-file (dir file)
  "Return FILE of the book in DIR."
  (expand-file-name file dir))

(ert-deftest gregorio-preview-test-tex-root ()
  (skip-unless (executable-find "git"))
  (gregorio-preview-test-with-book
    (let ((main (expand-file-name "main.tex" dir)))
      (dolist (file '("main.tex" "source/index.tex"
                      "source/partituras/hymn.tex"
                      "source/partituras/other.tex"))
        (should (file-equal-p (gregorio-preview--tex-root
                               (expand-file-name file dir))
                              main))))))

(ert-deftest gregorio-preview-test-score-reference-kinds ()
  (gregorio-preview-test-with-buffer ""
    (with-syntax-table gregorio-preview--tex-syntax-table
      (dolist (case '(("\\gregorioscore{hymn}" . t)
                      ("\\gregorioscore[a]{gabc/hymn.gabc}" . t)
                      ("\\MyScore*{gabc/hymn}" . t)
                      ("\\includescore{hymn}" . t)
                      ("\\input{source/partituras/hymn}" . nil)
                      ("\\label{hymn}" . nil)
                      ("\\includegraphics{hymn.png}" . nil)
                      ("\\gregorioscore{hymn.tex}" . nil)
                      ("% \\gregorioscore{hymn}" . nil)
                      ("\\gregorioscore{{{SCORE}}.gabc}" . nil)))
        (erase-buffer)
        (insert (car case))
        (should (eq (and (gregorio-preview--score-reference "hymn") t)
                    (cdr case)))))))

(ert-deftest gregorio-preview-test-find-master-book ()
  (skip-unless (executable-find "git"))
  (gregorio-preview-test-with-book
    (let ((master (gregorio-preview--find-master
                   (expand-file-name "source/gabc/hymn.gabc" dir))))
      (should (file-equal-p (car master) (expand-file-name "main.tex" dir)))
      (should (file-equal-p (cdr master)
                            (expand-file-name "source/partituras/hymn.tex"
                                              dir))))
    ;; A score that no file includes falls back to the main document.
    (let ((master (gregorio-preview--find-master
                   (expand-file-name "source/gabc/orphan.gabc" dir))))
      (should (file-equal-p (car master) (expand-file-name "main.tex" dir)))
      (should-not (cdr master)))))

(ert-deftest gregorio-preview-test-master-cache ()
  (skip-unless (executable-find "git"))
  (gregorio-preview-test-with-book
    (let ((gregorio-lsp-client nil)
          (enable-local-variables nil))
      (with-current-buffer (find-file-noselect
                            (expand-file-name "source/gabc/hymn.gabc" dir))
        (unwind-protect
            (let ((first (gregorio-preview--master)))
              (should first)
              (should gregorio-preview--master-cache)
              (should (equal (gregorio-preview--master) first)))
          (kill-buffer))))))

(ert-deftest gregorio-preview-test-master-preamble-includer ()
  (skip-unless (executable-find "git"))
  (gregorio-preview-test-with-book
    (let ((preamble (gregorio-preview--master-preamble
                     (expand-file-name "main.tex" dir) "hymn"
                     (expand-file-name "source/partituras/hymn.tex" dir))))
      (should (string-match-p "\\\\usepackage{preamble}" (car preamble)))
      ;; Setup commands before the score in the including file only.
      (should (equal (cdr preamble) "\\grechangestaffsize{15}")))))

(ert-deftest gregorio-preview-test-texinputs ()
  (gregorio-preview-test-with-project
    (let ((buffer-file-name (expand-file-name "scores/hymn.gabc" dir))
          (process-environment (cons "TEXINPUTS=/x:" process-environment)))
      (should (equal (gregorio-preview--texinputs
                      (list :master (expand-file-name "main.tex" dir)))
                     (list (concat "TEXINPUTS="
                                   (directory-file-name dir) path-separator
                                   (expand-file-name "scores" dir) path-separator
                                   "/x:")))))
    (let ((buffer-file-name nil))
      (should-not (gregorio-preview--texinputs nil)))))

(ert-deftest gregorio-preview-test-add-local-preamble ()
  (gregorio-preview-test-with-buffer gregorio-preview-test-text
    (gregorio-preview-add-local-preamble "\\usepackage{tikz}")
    (should (equal gregorio-preview-preamble "\\usepackage{tikz}"))
    (should (string-match-p
             "^% Local Variables:\n% gregorio-preview-preamble: \"\\\\\\\\usepackage{tikz}\"\n% End:"
             (buffer-string)))
    ;; The Local Variables block is not previewed.
    (should (= (length (gregorio-preview--chunks)) 4))))

(ert-deftest gregorio-preview-test-key ()
  (let ((settings '(:dpi 100 :width "300pt")))
    (should (equal (gregorio-preview--key "a" settings)
                   (gregorio-preview--key "a" (copy-sequence settings))))
    (should-not (equal (gregorio-preview--key "a" settings)
                       (gregorio-preview--key "b" settings)))
    (should-not (equal (gregorio-preview--key "a" settings)
                       (gregorio-preview--key "a" '(:dpi 200 :width "300pt"))))))

;;; Overlay states

(defun gregorio-preview-test-fake-preview ()
  "Put a shown preview with a dummy image on the line at point."
  (let ((ov (gregorio-preview--make-overlay (line-beginning-position)
                                            (line-end-position) "key")))
    (gregorio-preview--set-state ov 'shown '(image :type png :data ""))
    ov))

(ert-deftest gregorio-preview-test-overlay-toggle ()
  (gregorio-preview-test-with-buffer gregorio-preview-test-text
    (search-forward "Ma(h)")
    (let ((ov (gregorio-preview-test-fake-preview)))
      (should (eq (car (overlay-get ov 'display)) 'image))
      (should (overlay-get ov 'keymap))
      (gregorio-preview-toggle)
      (should (eq (overlay-get ov 'gregorio-preview) 'revealed))
      (should-not (overlay-get ov 'display))
      (should-not (overlay-get ov 'keymap))
      (gregorio-preview-at-point)
      (should (eq (overlay-get ov 'gregorio-preview) 'shown))
      (should (eq (car (overlay-get ov 'display)) 'image)))))

(ert-deftest gregorio-preview-test-overlay-auto-reveal ()
  (gregorio-preview-test-with-buffer gregorio-preview-test-text
    (search-forward "Ma(h)")
    (let ((ov (gregorio-preview-test-fake-preview))
          (gregorio-preview-auto-reveal t))
      (gregorio-preview--sensor nil nil 'entered)
      (should (eq (overlay-get ov 'gregorio-preview) 'revealed))
      (goto-char (point-min))
      (gregorio-preview--sensor nil nil 'left)
      (should (eq (overlay-get ov 'gregorio-preview) 'shown)))))

(ert-deftest gregorio-preview-test-overlay-edit-removes-preview ()
  (gregorio-preview-test-with-buffer gregorio-preview-test-text
    (search-forward "Ma(h)")
    (let ((ov (gregorio-preview-test-fake-preview)))
      (insert "x")
      (should-not (overlay-buffer ov)))))

(ert-deftest gregorio-preview-test-clearout ()
  (gregorio-preview-test-with-buffer gregorio-preview-test-text
    (search-forward "Ma(h)")
    (let ((ov1 (gregorio-preview-test-fake-preview)))
      (search-forward "ple")
      (let ((ov2 (gregorio-preview-test-fake-preview)))
        (gregorio-preview-clearout-at-point)
        (should-not (overlay-buffer ov2))
        (should (overlay-buffer ov1))
        (gregorio-preview-clearout-buffer)
        (should-not (overlay-buffer ov1))
        (should-error (gregorio-preview-toggle) :type 'user-error)))))

;;; Integration

(defun gregorio-preview-test-toolchain-p ()
  "Return non-nil if the preview toolchain is installed."
  (and (executable-find gregorio-preview-gregorio-command)
       (executable-find gregorio-preview-latex-command)
       (executable-find gregorio-preview-pdftocairo-command)
       (image-type-available-p 'png)))

(defun gregorio-preview-test-wait ()
  "Wait until the preview job of the current buffer ends."
  (let ((deadline (+ (float-time) 300)))
    (while (and gregorio-preview--current-job (< (float-time) deadline))
      (accept-process-output nil 0.1))
    (should-not gregorio-preview--current-job)))

(defun gregorio-preview-test-example (file)
  "Preview example FILE and check every line got an image."
  (with-temp-buffer
    (let ((gregorio-lsp-client nil))
      (insert-file-contents
       (expand-file-name (concat "../examples/" file)
                         gregorio-preview-test-directory))
      (gregorio-mode)
      (gregorio-preview-buffer)
      (gregorio-preview-test-wait)
      (let ((chunks (gregorio-preview--chunks))
            (overlays (gregorio-preview--overlays (point-min) (point-max))))
        (should (= (length overlays) (length chunks)))
        (dolist (ov overlays)
          (should (eq (overlay-get ov 'gregorio-preview) 'shown))
          (should (eq (car (overlay-get ov 'display)) 'image))))
      ;; Previewing again only reuses up-to-date images.
      (gregorio-preview-buffer)
      (should-not gregorio-preview--current-job))))

(ert-deftest gregorio-preview-test-integration-gabc ()
  (skip-unless (gregorio-preview-test-toolchain-p))
  (gregorio-preview-test-example "16-complete-chant.gabc"))

(ert-deftest gregorio-preview-test-integration-nabc ()
  (skip-unless (gregorio-preview-test-toolchain-p))
  (gregorio-preview-test-example "14-nabc-stgall.gabc"))

(ert-deftest gregorio-preview-test-integration-error ()
  (skip-unless (gregorio-preview-test-toolchain-p))
  (gregorio-preview-test-with-buffer "%%\n(c4) A(f)\nB(f\n"
    (gregorio-preview-buffer)
    (gregorio-preview-test-wait)
    (let ((states (mapcar (lambda (ov) (overlay-get ov 'gregorio-preview))
                          (sort (gregorio-preview--overlays (point-min)
                                                            (point-max))
                                (lambda (a b) (< (overlay-start a)
                                                 (overlay-start b)))))))
      (should (equal states '(shown error))))))

(defconst gregorio-preview-test-tikz-text
  "%%\n(c4) A(f) (,)\nB(g) <v>\\tikzmarknode{x}{C}</v>(h) (;)\nD(g) (::)\n"
  "Chant whose second line needs the tikzmark library.")

(defun gregorio-preview-test-states ()
  "Return the states of the previews in the buffer, in order."
  (mapcar (lambda (ov) (overlay-get ov 'gregorio-preview))
          (sort (gregorio-preview--overlays (point-min) (point-max))
                (lambda (a b) (< (overlay-start a) (overlay-start b))))))

(ert-deftest gregorio-preview-test-integration-latex-error-isolated ()
  (skip-unless (gregorio-preview-test-toolchain-p))
  (gregorio-preview-test-with-buffer gregorio-preview-test-tikz-text
    (gregorio-preview-buffer)
    (gregorio-preview-test-wait)
    (should (equal (gregorio-preview-test-states) '(shown error shown)))
    (search-forward "tikzmarknode")
    (should (string-match-p
             "Undefined control sequence \\\\tikzmarknode"
             (overlay-get (gregorio-preview--overlay-at (point))
                          'gregorio-preview-error)))))

(ert-deftest gregorio-preview-test-integration-preamble ()
  (skip-unless (gregorio-preview-test-toolchain-p))
  (gregorio-preview-test-with-buffer gregorio-preview-test-tikz-text
    (setq-local gregorio-preview-preamble
                "\\usepackage{tikz}\\usetikzlibrary{tikzmark}")
    (setq-local gregorio-preview-latex-passes 2)
    (gregorio-preview-buffer)
    (gregorio-preview-test-wait)
    (should (equal (gregorio-preview-test-states) '(shown shown shown)))))

(ert-deftest gregorio-preview-test-integration-master ()
  (skip-unless (gregorio-preview-test-toolchain-p))
  (gregorio-preview-test-with-project
    (let ((gregorio-lsp-client nil)
          (enable-local-variables nil))
      (with-current-buffer (find-file-noselect
                            (expand-file-name "scores/hymn.gabc" dir))
        (unwind-protect
            (progn
              (gregorio-preview-buffer)
              (gregorio-preview-test-wait)
              (should (equal (gregorio-preview-test-states) '(shown))))
          (set-buffer-modified-p nil)
          (kill-buffer))))))

(ert-deftest gregorio-preview-test-integration-book ()
  (skip-unless (and (gregorio-preview-test-toolchain-p)
                    (executable-find "git")))
  (gregorio-preview-test-with-book
    (let ((gregorio-lsp-client nil)
          (enable-local-variables nil))
      (with-current-buffer (find-file-noselect
                            (expand-file-name "source/gabc/hymn.gabc" dir))
        (unwind-protect
            (progn
              (gregorio-preview-buffer)
              (gregorio-preview-test-wait)
              (should (equal (gregorio-preview-test-states) '(shown))))
          (kill-buffer))))))

(provide 'gregorio-preview-test)

;;; gregorio-preview-test.el ends here
