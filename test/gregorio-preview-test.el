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
    (should (string-match-p "\\\\usepackage{gregoriotex}" tex))
    (should (string-match-p "\\\\usepackage\\[active,tightpage\\]{preview}" tex))
    (should (string-match-p "\\\\setlength{\\\\textwidth}{300pt}" tex))
    (should (string-match-p "\\\\color\\[HTML\\]{FFFFFF}" tex))
    (should (string-match-p "\\\\grechangestaffsize{15}" tex))
    (should (string-match-p
             "\\\\gresetinitiallines{1}\\\\gregorioscore\\[n\\]{chunk-1.gtex}"
             tex))
    (should (string-match-p
             "\\\\gresetinitiallines{0}\\\\gregorioscore\\[n\\]{chunk-2.gtex}"
             tex))))

(ert-deftest gregorio-preview-test-latex-document-without-color ()
  (should-not (string-match-p
               "\\\\color\\["
               (gregorio-preview--latex-document
                '(("chunk-1.gtex" . t)) '(:width "1pt" :preamble "")))))

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

(provide 'gregorio-preview-test)

;;; gregorio-preview-test.el ends here
