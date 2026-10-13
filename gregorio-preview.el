;;; gregorio-preview.el --- Inline score previews for gregorio-mode -*- lexical-binding: t; -*-

;; Copyright (C) 2026 AISCGre Brasil

;; Author: AISCGre Brasil
;; URL: https://github.com/AISCGre-BR/gregorio-mode
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Inline previews of GABC scores, in the spirit of AUCTeX's
;; preview-latex.  Each non-blank line of the chant body is engraved
;; separately and the rendered image replaces the source text in the
;; buffer.  RET or a mouse click on an image reveals the source again;
;; editing the source removes the preview.
;;
;; Each line is turned into a standalone GABC file that repeats the
;; buffer header and the clef in effect, compiled with `gregorio', and
;; all lines are typeset in a single LuaLaTeX run using GregorioTeX and
;; the preview package.  Every page of the resulting PDF is converted to
;; an image with `pdftocairo'.  All of this runs asynchronously.
;;
;; Scores often use LaTeX code from packages loaded by the document that
;; includes them.  The preview document therefore reuses the preamble
;; of that master document, found automatically or set with
;; `gregorio-preview-master', plus `gregorio-preview-preamble', which can
;; also be set as a file-local variable.  LaTeX errors are reported on
;; the line that caused them, without discarding the other previews.
;;
;; Requirements: gregorio, LuaLaTeX with GregorioTeX and preview.sty
;; (both part of TeX Live), and pdftocairo (poppler).
;;
;; Key bindings (in `gregorio-mode'):
;;
;;   C-c C-p C-p      preview or toggle the line at point
;;   C-c C-p C-r      preview the region
;;   C-c C-p C-b      preview the whole body
;;   C-c C-p C-c C-p  clear the preview at point
;;   C-c C-p C-c C-r  clear previews in the region
;;   C-c C-p C-c C-b  clear all previews in the buffer
;;   C-c C-p C-e      explain the preview error at point
;;   C-c C-p C-k      abort the running preview job

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'gregorio-mode)
(require 'project)

(defgroup gregorio-preview nil
  "Inline score previews for `gregorio-mode'."
  :group 'gregorio
  :prefix "gregorio-preview-")

(defcustom gregorio-preview-gregorio-command "gregorio"
  "Executable of the Gregorio GABC compiler."
  :type 'string)

(defcustom gregorio-preview-latex-command "lualatex"
  "Executable of LuaLaTeX, used to typeset the previews."
  :type 'string)

(defcustom gregorio-preview-latex-args
  '("-interaction=nonstopmode" "-file-line-error")
  "Arguments passed to `gregorio-preview-latex-command'.
The name of the generated TeX file is appended to them."
  :type '(repeat string))

(defcustom gregorio-preview-pdftocairo-command "pdftocairo"
  "Executable of pdftocairo (poppler), used to convert PDF pages to images."
  :type 'string)

(defcustom gregorio-preview-latex-passes 1
  "Number of LuaLaTeX runs for each preview job.
Use 2 for packages that need a second run to place their elements,
such as tikzmark with `remember picture'."
  :type 'natnum
  :safe (lambda (v) (and (natnump v) (<= 1 v 3))))

(defcustom gregorio-preview-master nil
  "LaTeX master document whose preamble is used by the previews.
nil looks for a .tex file that includes the score with
`\\gregorioscore' (see `gregorio-preview-master-search-depth'); `none'
uses no master document; a file name uses that document.  A relative
file name is relative to the directory of the GABC file.

This is usually set as a file-local or directory-local variable."
  :type '(choice (const :tag "Find automatically" nil)
                 (const :tag "No master document" none)
                 (file :tag "Master document"))
  :safe (lambda (v) (memq v '(nil none))))

(defcustom gregorio-preview-master-search-depth 3
  "How many parent directories to search for a master document.
The search starts in the directory of the GABC file and never goes
above the root of its project."
  :type 'natnum)

(defcustom gregorio-preview-preamble ""
  "Extra LaTeX code inserted in the preamble of the preview document.
It comes after the preamble of the master document, if any.  Use it
to load packages needed by LaTeX code inside the score, or to change
fonts or GregorioTeX settings, for example
\"\\\\usepackage{tikz}\\\\usetikzlibrary{tikzmark}\" or
\"\\\\grechangestaffsize{15}\".

It can be set per file with `gregorio-preview-add-local-preamble'.
Since LuaLaTeX can run Lua code, Emacs asks before applying a
file-local value."
  :type 'string)

(defcustom gregorio-preview-scale 1.0
  "Scale factor of the preview images.
At 1.0, the text of the score has roughly the height of the default
face."
  :type 'number)

(defcustom gregorio-preview-image-type 'png
  "Image format used for the previews."
  :type '(choice (const :tag "PNG" png)
                 (const :tag "SVG" svg)))

(defcustom gregorio-preview-text-width nil
  "Line width of the previews.
nil uses the width of the window showing the buffer; otherwise a TeX
dimension such as \"15cm\"."
  :type '(choice (const :tag "Window width" nil)
                 (string :tag "TeX dimension")))

(defcustom gregorio-preview-use-face-color t
  "When non-nil, render scores in the foreground color of the default face.
This keeps previews readable with dark themes."
  :type 'boolean)

(defcustom gregorio-preview-auto-reveal t
  "When non-nil, reveal the source of a preview when point enters it.
The image is shown again when point leaves the line, unless the
source was edited."
  :type 'boolean)

(defface gregorio-preview-busy-face '((t :inherit shadow))
  "Face of the indicator shown while a preview is being generated."
  :group 'gregorio-preview)

(defface gregorio-preview-error-face '((t :inherit error))
  "Face of the indicator shown when a preview failed."
  :group 'gregorio-preview)

;;; ---------------------------------------------------------------------------
;;; Chunks
;;; ---------------------------------------------------------------------------

(defconst gregorio-preview--clef-regexp
  "\\(?:cb\\|[cf]\\)[1-5]\\(?:@\\(?:cb\\|[cf]\\)[1-5]\\)?"
  "Regexp matching a clef, optionally followed by a second clef.")

(defun gregorio-preview--chunk-line-p ()
  "Return non-nil if the current line holds GABC code to preview.
Blank lines and lines holding only a comment are skipped."
  (save-excursion
    (beginning-of-line)
    (not (looking-at-p "[ \t]*\\(?:%.*\\)?$"))))

(defun gregorio-preview--header (first)
  "Return the header of the buffer for a preview chunk.
Unless FIRST is non-nil, `annotation' lines are removed, since only
the first line of the score carries them."
  (let ((header (buffer-substring-no-properties
                 (point-min) (gregorio--separator-start))))
    (if first
        header
      (replace-regexp-in-string
       "^[ \t]*annotation[ \t]*:.*\n?" "" header t t))))

(defun gregorio-preview--clef-before (pos groups)
  "Return the last clef found in GROUPS before POS, or nil.
GROUPS is a list of (OPEN . CLOSE) note group positions."
  (let ((case-fold-search nil) clef)
    (save-excursion
      (dolist (group groups)
        (when (and (< (car group) pos)
                   (gregorio--clef-group-p (car group) (cdr group)))
          (goto-char (1+ (car group)))
          (when (re-search-forward gregorio-preview--clef-regexp
                                   (cdr group) t)
            (setq clef (match-string-no-properties 0))))))
    clef))

(defun gregorio-preview--starts-with-clef-p (bol eol groups)
  "Return non-nil if the first note group between BOL and EOL is a clef.
GROUPS is a list of (OPEN . CLOSE) note group positions."
  (let ((first (cl-find-if (lambda (g) (and (>= (car g) bol) (< (car g) eol)))
                           groups)))
    (and first (gregorio--clef-group-p (car first) (cdr first)))))

(defun gregorio-preview--chunks (&optional beg end)
  "Return the preview chunks of the body between BEG and END.
Each chunk is a list (START END GABC FIRST): START and END delimit a
body line, GABC is a standalone GABC document engraving that line and
FIRST is non-nil for the first line of the body.  The
document repeats the buffer header and, when the line does not begin
with a clef, prepends the clef in effect.  Only the first line of the
body keeps the initial and the annotation."
  (gregorio--require-body)
  (save-excursion
    (save-restriction
      (widen)
      (let* ((body (gregorio--body-start))
             (beg (max body (or beg body)))
             (end (or end (point-max)))
             (groups (gregorio--body-groups))
             (first-line (progn (goto-char body)
                                (while (and (not (eobp))
                                            (not (gregorio-preview--chunk-line-p)))
                                  (forward-line 1))
                                (point)))
             chunks)
        (goto-char beg)
        (beginning-of-line)
        (while (and (< (point) end) (not (eobp)))
          (let ((bol (point))
                (eol (line-end-position)))
            (when (gregorio-preview--chunk-line-p)
              (let* ((first (= bol first-line))
                     (clef (and (not (gregorio-preview--starts-with-clef-p
                                      bol eol groups))
                                (gregorio-preview--clef-before bol groups))))
                (push (list bol eol
                            (concat (gregorio-preview--header first)
                                    "%%\n"
                                    (if clef (format "(%s) " clef) "")
                                    (buffer-substring-no-properties bol eol)
                                    "\n")
                            first)
                      chunks)))
            (forward-line 1)))
        (nreverse chunks)))))

;;; ---------------------------------------------------------------------------
;;; Master document
;;; ---------------------------------------------------------------------------

(defvar gregorio-preview--tex-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?\\ "\\" table)
    (modify-syntax-entry ?% "<" table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?{ "(}" table)
    (modify-syntax-entry ?} "){" table)
    (modify-syntax-entry ?\[ "(]" table)
    (modify-syntax-entry ?\] ")[" table)
    (modify-syntax-entry ?\( "." table)
    (modify-syntax-entry ?\) "." table)
    (modify-syntax-entry ?\" "." table)
    table)
  "Syntax table used to scan LaTeX documents.")

(defconst gregorio-preview--score-regexp
  "\\\\\\(?:gregorioscore\\|includescore\\)\\*?[ \t\n]*\\(?:\\[[^]]*\\][ \t\n]*\\)?{\\([^}]*\\)}"
  "Regexp matching a GregorioTeX command that includes a score file.")

(defconst gregorio-preview--setup-regexp
  "\\\\gre\\(?:set\\|change\\)[A-Za-z]+"
  "Regexp matching GregorioTeX setup commands.")

(defun gregorio-preview--in-comment-p ()
  "Return non-nil if point is inside a LaTeX comment."
  (nth 4 (syntax-ppss)))

(defun gregorio-preview--score-reference (name)
  "Return the position of the first score inclusion of NAME, or nil.
NAME is the base name of a GABC file, without directory and extension.
The current buffer holds a LaTeX document."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search nil) found)
      (while (and (not found)
                  (re-search-forward gregorio-preview--score-regexp nil t))
        (when (and (not (save-excursion
                          (goto-char (match-beginning 0))
                          (gregorio-preview--in-comment-p)))
                   (equal (file-name-base (string-trim (match-string 1)))
                          name))
          (setq found (match-beginning 0))))
      found)))

(defmacro gregorio-preview--with-tex-file (file &rest body)
  "Run BODY in a temporary buffer holding the LaTeX document FILE."
  (declare (indent 1))
  `(with-temp-buffer
     (insert-file-contents ,file)
     (set-syntax-table gregorio-preview--tex-syntax-table)
     ,@body))

(defun gregorio-preview--search-directories (file)
  "Return the directories searched for the master document of FILE."
  (let* ((dir (file-name-directory (expand-file-name file)))
         (project (project-current nil dir))
         (root (and project (expand-file-name (project-root project))))
         dirs)
    (dotimes (_ (1+ gregorio-preview-master-search-depth))
      (when dir
        (push dir dirs)
        (let ((parent (file-name-directory (directory-file-name dir))))
          (setq dir (and (not (and root (file-equal-p dir root)))
                         (not (equal parent dir))
                         parent)))))
    (nreverse dirs)))

(defun gregorio-preview--find-master (file)
  "Return a LaTeX document that includes the GABC FILE, or nil."
  (let ((name (file-name-base file)))
    (cl-loop for dir in (gregorio-preview--search-directories file)
             thereis (cl-loop
                      for tex in (directory-files dir t "\\.tex\\'" t)
                      thereis (and (file-regular-p tex)
                                   (file-readable-p tex)
                                   (gregorio-preview--with-tex-file tex
                                     (gregorio-preview--score-reference name))
                                   tex)))))

(defun gregorio-preview--master-file ()
  "Return the master document of the current buffer, or nil."
  (pcase gregorio-preview-master
    ('none nil)
    ((and (pred stringp) master)
     (let ((file (expand-file-name master)))
       (unless (file-readable-p file)
         (user-error "Master document %s not found" master))
       file))
    (_ (and buffer-file-name
            (gregorio-preview--find-master buffer-file-name)))))

(defun gregorio-preview--command-at-point ()
  "Return the LaTeX command at point with its arguments, as a string.
Point is at the backslash of the command and is moved after it."
  (let ((start (point)))
    (skip-chars-forward "\\\\")
    (skip-chars-forward "A-Za-z@")
    (while (save-excursion
             (skip-chars-forward " \t")
             (memq (char-after) '(?{ ?\[)))
      (skip-chars-forward " \t")
      (forward-sexp 1))
    (buffer-substring-no-properties start (point))))

(defun gregorio-preview--master-preamble (file name)
  "Return the preamble of the LaTeX document FILE as (PREAMBLE . SETUP).
PREAMBLE is the text before \\begin{document}.  SETUP holds the
GregorioTeX setup commands of the document body that come before the
inclusion of the score NAME (or anywhere in the body if NAME is not
included), except \\gresetinitiallines.  Return nil when FILE has no
\\begin{document}."
  (gregorio-preview--with-tex-file file
    (goto-char (point-min))
    (let ((case-fold-search nil) begin)
      (while (and (not begin)
                  (search-forward "\\begin{document}" nil t))
        (unless (save-excursion (goto-char (match-beginning 0))
                                (gregorio-preview--in-comment-p))
          (setq begin (match-beginning 0))))
      (when begin
        (let ((preamble (buffer-substring-no-properties (point-min) begin))
              (limit (or (gregorio-preview--score-reference name) (point-max)))
              setup)
          (goto-char begin)
          (while (re-search-forward gregorio-preview--setup-regexp limit t)
            (goto-char (match-beginning 0))
            (if (or (gregorio-preview--in-comment-p)
                    (looking-at-p "\\\\gresetinitiallines\\b"))
                (goto-char (match-end 0))
              (push (condition-case nil
                        (gregorio-preview--command-at-point)
                      (scan-error (goto-char (match-end 0)) nil))
                    setup)))
          (cons preamble (string-join (delq nil (nreverse setup)) "\n")))))))

;;; ---------------------------------------------------------------------------
;;; Rendering parameters
;;; ---------------------------------------------------------------------------

(defun gregorio-preview--dpi ()
  "Return the resolution of the preview images, in dots per inch."
  (let ((char-height (if (display-graphic-p) (frame-char-height) 16)))
    ;; A 10pt TeX font is about 12pt from baseline to baseline.
    (max 30 (round (* gregorio-preview-scale char-height (/ 72.27 12))))))

(defun gregorio-preview--text-width (dpi)
  "Return the TeX line width of the previews for resolution DPI."
  (or gregorio-preview-text-width
      (let* ((window (or (get-buffer-window nil t) (selected-window)))
             (pixels (if (display-graphic-p)
                         (window-body-width window t)
                       (* 80 8))))
        (format "%.2fpt" (/ (* 0.95 pixels 72.27) dpi)))))

(defun gregorio-preview--color ()
  "Return the foreground color for the scores as RRGGBB, or nil."
  (when gregorio-preview-use-face-color
    (let* ((color (face-foreground 'default nil t))
           (values (and color (color-values color))))
      (when values
        (apply #'format "%02X%02X%02X"
               (mapcar (lambda (v) (/ v 256)) values))))))

(defun gregorio-preview--settings ()
  "Return the rendering settings for the current buffer as a plist."
  (let* ((dpi (gregorio-preview--dpi))
         (master (gregorio-preview--master-file))
         (name (and buffer-file-name (file-name-base buffer-file-name)))
         (preamble (and master (gregorio-preview--master-preamble master name))))
    (list :dpi dpi
          :width (gregorio-preview--text-width dpi)
          :color (gregorio-preview--color)
          :type gregorio-preview-image-type
          :passes (max 1 gregorio-preview-latex-passes)
          :master (and preamble master)
          :master-preamble (car preamble)
          :master-setup (cdr preamble)
          :preamble gregorio-preview-preamble)))

(defun gregorio-preview--key (gabc settings)
  "Return the cache key of a chunk with text GABC and SETTINGS."
  (md5 (prin1-to-string (cons gabc settings))))

(defun gregorio-preview--latex-document (files settings)
  "Return the LaTeX source typesetting FILES with SETTINGS.
FILES is a list of (GTEX-FILE . FIRST) pairs; FIRST is non-nil for the
chunk that carries the initial of the score.  The preamble of the
master document, when there is one, replaces the default document
class."
  (let ((color (plist-get settings :color))
        (setup (plist-get settings :master-setup)))
    (concat
     "\\PassOptionsToPackage{active,tightpage,auctex}{preview}\n"
     (or (plist-get settings :master-preamble)
         "\\documentclass{article}\n")
     "\n\\usepackage{xcolor}\n"
     "\\usepackage{gregoriotex}\n"
     "\\usepackage{preview}\n"
     (plist-get settings :preamble) "\n"
     "\\begin{document}\n"
     (if (and setup (not (string-empty-p setup))) (concat setup "\n") "")
     (format "\\setlength{\\textwidth}{%s}\n" (plist-get settings :width))
     "\\setlength{\\linewidth}{\\textwidth}\\setlength{\\hsize}{\\textwidth}\n"
     (if color (format "\\color[HTML]{%s}\n" color) "")
     (mapconcat
      (lambda (file)
        (format "\\begin{preview}\\gresetinitiallines{%d}\\gregorioscore[n]{%s}\\end{preview}\n"
                (if (cdr file) 1 0) (car file)))
      files "")
     "\\end{document}\n")))

;;; ---------------------------------------------------------------------------
;;; LaTeX log
;;; ---------------------------------------------------------------------------

(defconst gregorio-preview--error-regexp
  "^\\(?:! \\|[^ \n]*:[0-9]+: \\)\\(.+\\)$"
  "Regexp matching a LaTeX error line, in either error format.")

(defun gregorio-preview--error-message (lines i)
  "Return the error message of line I of the log LINES (a vector)."
  (let ((message (match-string 1 (aref lines i))))
    (if (and (string-prefix-p "Undefined control sequence" message)
             (< (1+ i) (length lines))
             (string-match "\\(\\\\\\(?:[A-Za-z@]+\\|.\\)\\)[ \t]*$"
                           (aref lines (1+ i))))
        (format "Undefined control sequence %s"
                (match-string 1 (aref lines (1+ i))))
      message)))

(defun gregorio-preview--parse-log (log)
  "Parse the LaTeX LOG of a preview run.
Return a plist with :pages, the number of pages written (0 when
none), :global, the errors raised outside snippets, and :snippets, an
alist mapping each snippet number to a plist with :ended and :errors.
Error lists keep the order of the log, without duplicates."
  (let ((lines (vconcat (split-string log "\n")))
        (pages 0) global snippets current)
    (dotimes (i (length lines))
      (let ((line (aref lines i)))
        (cond
         ((string-match "Preview: Snippet \\([0-9]+\\) started" line)
          (setq current (string-to-number (match-string 1 line)))
          (push (list current :ended nil :errors nil) snippets))
         ((string-match "Preview: Snippet \\([0-9]+\\) ended" line)
          (let ((entry (assq (string-to-number (match-string 1 line))
                             snippets)))
            (when entry (setf (plist-get (cdr entry) :ended) t)))
          (setq current nil))
         ((string-match "Output written on .*(\\([0-9]+\\) pages?" line)
          (setq pages (string-to-number (match-string 1 line))))
         ((and (string-match gregorio-preview--error-regexp line)
               (not (string-match-p "Preview: " line)))
          (let ((message (gregorio-preview--error-message lines i))
                (entry (and current (assq current snippets))))
            (if entry
                (unless (member message (plist-get (cdr entry) :errors))
                  (setf (plist-get (cdr entry) :errors)
                        (append (plist-get (cdr entry) :errors)
                                (list message))))
              (unless (member message global)
                (setq global (append global (list message))))))))))
    (list :pages pages :global global :snippets (nreverse snippets))))

(defun gregorio-preview--snippet-error (parsed index)
  "Return the error of snippet INDEX in the PARSED log, or nil if it worked."
  (let* ((entry (cdr (assq index (plist-get parsed :snippets))))
         (errors (append (plist-get parsed :global)
                         (plist-get entry :errors))))
    (cond
     (errors (string-join errors "; "))
     ((not (plist-get entry :ended)) "LaTeX stopped before this line")
     ((> index (plist-get parsed :pages)) "LaTeX produced no page"))))

;;; ---------------------------------------------------------------------------
;;; Overlays
;;; ---------------------------------------------------------------------------

(defvar-keymap gregorio-preview-overlay-map
  :doc "Keymap active on a shown preview image."
  "RET" #'gregorio-preview-toggle
  "<mouse-2>" #'gregorio-preview-toggle
  "<down-mouse-1>" #'ignore
  "<mouse-1>" #'gregorio-preview-toggle)

(defvar-keymap gregorio-preview-error-map
  :doc "Keymap active on the indicator of a failed preview."
  "<down-mouse-1>" #'ignore
  "<mouse-1>" #'gregorio-preview-explain-error
  "<mouse-2>" #'gregorio-preview-explain-error)

(defun gregorio-preview--overlays (beg end)
  "Return the preview overlays overlapping BEG..END."
  (cl-remove-if-not (lambda (ov) (overlay-get ov 'gregorio-preview))
                    (overlays-in beg end)))

(defun gregorio-preview--overlay-at (pos)
  "Return the preview overlay on the line at POS, or nil."
  (save-excursion
    (goto-char pos)
    (car (gregorio-preview--overlays (line-beginning-position)
                                     (max (1+ (line-beginning-position))
                                          (line-end-position))))))

(defun gregorio-preview--set-state (ov state &optional data)
  "Put preview overlay OV in STATE.
STATE is one of `busy', `shown', `revealed' or `error'.  DATA is the
image for `shown' and the error message for `error'."
  (overlay-put ov 'gregorio-preview state)
  (dolist (prop '(display keymap before-string help-echo mouse-face))
    (overlay-put ov prop nil))
  (pcase state
    ('busy
     (overlay-put ov 'before-string
                  (propertize "⧗ " 'face 'gregorio-preview-busy-face))
     (overlay-put ov 'help-echo "Generating preview..."))
    ('shown
     (when data (overlay-put ov 'gregorio-preview-image data))
     (overlay-put ov 'display (overlay-get ov 'gregorio-preview-image))
     (overlay-put ov 'keymap gregorio-preview-overlay-map)
     (overlay-put ov 'mouse-face 'highlight)
     (overlay-put ov 'help-echo "mouse-1, RET: show source"))
    ('error
     (overlay-put ov 'gregorio-preview-error data)
     (let ((echo (concat data "\nmouse-1, C-c C-p C-e: explain")))
       (overlay-put ov 'before-string
                    (propertize "⚠ " 'face 'gregorio-preview-error-face
                                'mouse-face 'highlight
                                'keymap gregorio-preview-error-map
                                'help-echo echo))
       (overlay-put ov 'help-echo echo)))))

(defun gregorio-preview--modified (ov after &rest _)
  "Remove preview overlay OV when its text is modified.
AFTER is non-nil when called after the change."
  (when after
    (delete-overlay ov)))

(defun gregorio-preview--sensor (_window _oldpos direction)
  "Reveal or hide the preview at point according to DIRECTION.
This is a `cursor-sensor-functions' handler."
  (when gregorio-preview-auto-reveal
    (pcase direction
      ('entered
       (let ((ov (gregorio-preview--overlay-at (point))))
         (when (and ov (eq (overlay-get ov 'gregorio-preview) 'shown))
           (gregorio-preview--set-state ov 'revealed)
           (overlay-put ov 'gregorio-preview-auto t))))
      ('left
       (dolist (ov (gregorio-preview--overlays (point-min) (point-max)))
         (when (and (overlay-get ov 'gregorio-preview-auto)
                    (eq (overlay-get ov 'gregorio-preview) 'revealed)
                    (not (and (>= (point) (overlay-start ov))
                              (<= (point) (overlay-end ov)))))
           (overlay-put ov 'gregorio-preview-auto nil)
           (gregorio-preview--set-state ov 'shown)))))))

(defun gregorio-preview--make-overlay (start end key)
  "Create a busy preview overlay from START to END with cache KEY."
  (let ((ov (make-overlay start end nil nil nil)))
    (overlay-put ov 'gregorio-preview-key key)
    (overlay-put ov 'evaporate t)
    (overlay-put ov 'modification-hooks '(gregorio-preview--modified))
    (overlay-put ov 'insert-in-front-hooks '(gregorio-preview--modified))
    (overlay-put ov 'cursor-sensor-functions '(gregorio-preview--sensor))
    (gregorio-preview--set-state ov 'busy)
    ov))

;;; ---------------------------------------------------------------------------
;;; Asynchronous jobs
;;; ---------------------------------------------------------------------------

(cl-defstruct (gregorio-preview--job (:constructor gregorio-preview--job-create)
                                     (:copier nil))
  "A running preview job."
  buffer dir settings chunks process env)

(defvar-local gregorio-preview--current-job nil
  "The preview job running in this buffer, or nil.")

(defconst gregorio-preview--log-buffer "*gregorio-preview*"
  "Name of the buffer holding the output of the preview tools.")

(defun gregorio-preview--log (format-string &rest args)
  "Append FORMAT-STRING formatted with ARGS to the preview log."
  (with-current-buffer (get-buffer-create gregorio-preview--log-buffer)
    (goto-char (point-max))
    (insert (apply #'format format-string args))))

(defun gregorio-preview--check-executables ()
  "Signal a `user-error' if a tool needed for previews is missing."
  (let ((missing (cl-remove-if
                  #'executable-find
                  (list gregorio-preview-gregorio-command
                        gregorio-preview-latex-command
                        gregorio-preview-pdftocairo-command))))
    (when missing
      (user-error "Preview needs %s on `exec-path'"
                  (string-join missing ", ")))))

(defun gregorio-preview--job-live-p (job)
  "Return non-nil if JOB is still the current job of its buffer."
  (and (buffer-live-p (gregorio-preview--job-buffer job))
       (eq job (buffer-local-value 'gregorio-preview--current-job
                                   (gregorio-preview--job-buffer job)))))

(defun gregorio-preview--run (job program args callback)
  "Run PROGRAM with ARGS in the directory of JOB.
CALLBACK is called with the exit status when PROGRAM finishes and JOB
is still current."
  (let ((default-directory (file-name-as-directory
                            (gregorio-preview--job-dir job)))
        (process-environment (append (gregorio-preview--job-env job)
                                     process-environment)))
    (gregorio-preview--log "$ %s %s\n" program (string-join args " "))
    (setf (gregorio-preview--job-process job)
          (make-process
           :name "gregorio-preview"
           :command (cons program args)
           :buffer (get-buffer-create gregorio-preview--log-buffer)
           :noquery t
           :connection-type 'pipe
           :sentinel
           (lambda (process _event)
             (when (memq (process-status process) '(exit signal))
               (if (gregorio-preview--job-live-p job)
                   (funcall callback (process-exit-status process))
                 (gregorio-preview--cleanup job))))))))

(defun gregorio-preview--run-sequence (job steps callback)
  "Run STEPS of JOB one after another, then call CALLBACK.
Each step is a list (PROGRAM ARGS ON-EXIT); ON-EXIT is called with the
exit status of PROGRAM."
  (if (null steps)
      (funcall callback)
    (pcase-let ((`(,program ,args ,on-exit) (car steps)))
      (gregorio-preview--run
       job program args
       (lambda (status)
         (funcall on-exit status)
         (gregorio-preview--run-sequence job (cdr steps) callback))))))

(defun gregorio-preview--read-file (file)
  "Return the contents of FILE as a string, or nil if it does not exist."
  (when (file-exists-p file)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (buffer-string))))

(defun gregorio-preview--fail (job ov message)
  "Mark preview overlay OV of JOB as failed with MESSAGE."
  (when (overlay-buffer ov)
    (gregorio-preview--set-state ov 'error message))
  (setf (gregorio-preview--job-chunks job)
        (delq (assq ov (gregorio-preview--job-chunks job))
              (gregorio-preview--job-chunks job))))

(defun gregorio-preview--cleanup (job)
  "Delete the temporary files of JOB."
  (let ((dir (gregorio-preview--job-dir job)))
    (when (and dir (file-directory-p dir))
      (delete-directory dir t))))

(defun gregorio-preview--finish (job)
  "End JOB, deleting its files and leftover busy overlays."
  (dolist (chunk (copy-sequence (gregorio-preview--job-chunks job)))
    (let ((ov (car chunk)))
      (when (and (overlay-buffer ov)
                 (eq (overlay-get ov 'gregorio-preview) 'busy))
        (gregorio-preview--fail job ov "Preview failed"))))
  (gregorio-preview--cleanup job)
  (let ((buffer (gregorio-preview--job-buffer job)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (eq gregorio-preview--current-job job)
          (setq gregorio-preview--current-job nil))))))

(defun gregorio-preview--compile-steps (job)
  "Return the steps compiling the GABC chunks of JOB with gregorio."
  (mapcar
   (lambda (chunk)
     (pcase-let ((`(,ov ,name . ,_) chunk))
       (list gregorio-preview-gregorio-command
             (list "-l" (concat name ".msg") "-o" (concat name ".gtex")
                   (concat name ".gabc"))
             (lambda (status)
               (let ((dir (gregorio-preview--job-dir job)))
                 (unless (and (zerop status)
                              (file-exists-p
                               (expand-file-name (concat name ".gtex") dir)))
                   (let ((msg (string-trim
                               (or (gregorio-preview--read-file
                                    (expand-file-name (concat name ".msg") dir))
                                   ""))))
                     (gregorio-preview--log "%s\n" msg)
                     (gregorio-preview--fail
                      job ov (if (string-empty-p msg) "gregorio failed"
                               (decode-coding-string msg 'utf-8))))))))))
   (gregorio-preview--job-chunks job)))

(defun gregorio-preview--image-steps (job pages)
  "Return the steps converting PAGES of the PDF of JOB to images.
PAGES is the list of page numbers to convert."
  (let ((dpi (number-to-string (plist-get (gregorio-preview--job-settings job)
                                          :dpi)))
        (ignore-status #'ignore))
    (if (eq (plist-get (gregorio-preview--job-settings job) :type) 'svg)
        (cl-loop for i in pages
                 collect (list gregorio-preview-pdftocairo-command
                               (list "-svg" "-f" (number-to-string i)
                                     "-l" (number-to-string i)
                                     "preview.pdf" (format "page-%d.svg" i))
                               ignore-status))
      (and pages
           (list (list gregorio-preview-pdftocairo-command
                       (list "-png" "-transp" "-r" dpi "preview.pdf" "page")
                       ignore-status))))))

(defun gregorio-preview--page-file (job index count)
  "Return the image file of page INDEX (1-based) of COUNT pages in JOB."
  (let ((dir (gregorio-preview--job-dir job)))
    (if (eq (plist-get (gregorio-preview--job-settings job) :type) 'svg)
        (expand-file-name (format "page-%d.svg" index) dir)
      ;; pdftocairo pads page numbers to the width of the page count.
      (expand-file-name
       (format (format "page-%%0%dd.png" (length (number-to-string count)))
               index)
       dir))))

(defun gregorio-preview--install-images (job pages count)
  "Show the images of PAGES produced by JOB on its overlays.
PAGES is an alist mapping page numbers to chunks; COUNT is the number
of pages of the PDF."
  (let ((type (plist-get (gregorio-preview--job-settings job) :type)))
    (pcase-dolist (`(,page . ,chunk) pages)
      (let ((ov (car chunk))
            (data (gregorio-preview--read-file
                   (gregorio-preview--page-file job page count))))
        (when (overlay-buffer ov)
          (if data
              (gregorio-preview--set-state
               ov 'shown (create-image data type t :ascent 'center))
            (gregorio-preview--fail job ov "No image produced")))))))

(defun gregorio-preview--latex-steps (job)
  "Return the LuaLaTeX steps of JOB."
  (make-list (plist-get (gregorio-preview--job-settings job) :passes)
             (list gregorio-preview-latex-command
                   (append gregorio-preview-latex-args '("preview.tex"))
                   #'ignore)))

(defun gregorio-preview--typeset (job)
  "Typeset the compiled chunks of JOB and install the resulting images.
Each chunk is a snippet of the preview document; chunks whose snippet
raised a LaTeX error are marked as failed, the others get the image
of their page."
  (let ((chunks (gregorio-preview--job-chunks job))
        (dir (gregorio-preview--job-dir job)))
    (if (null chunks)
        (gregorio-preview--finish job)
      (with-temp-file (expand-file-name "preview.tex" dir)
        (insert (gregorio-preview--latex-document
                 (mapcar (lambda (chunk)
                           (cons (concat (nth 1 chunk) ".gtex") (nth 2 chunk)))
                         chunks)
                 (gregorio-preview--job-settings job))))
      (gregorio-preview--run-sequence
       job (gregorio-preview--latex-steps job)
       (lambda ()
         (let* ((log (decode-coding-string
                      (or (gregorio-preview--read-file
                           (expand-file-name "preview.log" dir))
                          "")
                      'utf-8))
                (parsed (gregorio-preview--parse-log log))
                pages)
           (cl-loop for chunk in chunks
                    for i from 1
                    do (let ((error (gregorio-preview--snippet-error parsed i)))
                         (if error
                             (gregorio-preview--fail job (car chunk) error)
                           (push (cons i chunk) pages))))
           (setq pages (nreverse pages))
           (when (or (plist-get parsed :global)
                     (< (length pages) (length chunks)))
             (gregorio-preview--log "\n%s\n" log))
           (gregorio-preview--run-sequence
            job (gregorio-preview--image-steps job (mapcar #'car pages))
            (lambda ()
              (gregorio-preview--install-images job pages
                                                (plist-get parsed :pages))
              (gregorio-preview--finish job)))))))))

(defun gregorio-preview--texinputs (settings)
  "Return the TEXINPUTS environment entry for SETTINGS, or nil.
The directories of the master document and of the GABC file come
first, so that relative \\input and \\usepackage calls work."
  (let ((dirs (delete-dups
               (delq nil
                     (list (let ((master (plist-get settings :master)))
                             (and master (file-name-directory master)))
                           (and buffer-file-name
                                (file-name-directory buffer-file-name)))))))
    (when dirs
      (list (concat "TEXINPUTS="
                    (mapconcat (lambda (dir)
                                 (directory-file-name (expand-file-name dir)))
                               dirs path-separator)
                    path-separator
                    (or (getenv "TEXINPUTS") ""))))))

(defun gregorio-preview--start (beg end)
  "Generate previews for the body lines between BEG and END."
  (gregorio-preview--check-executables)
  (gregorio-preview-abort)
  (let* ((settings (gregorio-preview--settings))
         (dir (make-temp-file "gregorio-preview-" t))
         (job (gregorio-preview--job-create
               :buffer (current-buffer) :dir dir :settings settings
               :env (gregorio-preview--texinputs settings)))
         (n 0)
         chunks)
    (dolist (chunk (gregorio-preview--chunks beg end))
      (pcase-let* ((`(,start ,stop ,gabc ,first) chunk)
                   (key (gregorio-preview--key gabc settings))
                   (old (gregorio-preview--overlays start stop)))
        (unless (and (= (length old) 1)
                     (memq (overlay-get (car old) 'gregorio-preview)
                           '(shown revealed))
                     (equal (overlay-get (car old) 'gregorio-preview-key) key)
                     (= (overlay-start (car old)) start)
                     (= (overlay-end (car old)) stop))
          (mapc #'delete-overlay old)
          (let ((name (format "chunk-%d" (cl-incf n))))
            (with-temp-file (expand-file-name (concat name ".gabc") dir)
              (set-buffer-file-coding-system 'utf-8-unix)
              (insert gabc))
            (push (list (gregorio-preview--make-overlay start stop key)
                        name first)
                  chunks)))))
    (if (null chunks)
        (progn (delete-directory dir t)
               (message "Previews are up to date"))
      (when gregorio-preview-auto-reveal
        (cursor-sensor-mode 1))
      (with-current-buffer (get-buffer-create gregorio-preview--log-buffer)
        (let ((inhibit-read-only t))
          (erase-buffer)))
      (setf (gregorio-preview--job-chunks job) (nreverse chunks))
      (setq gregorio-preview--current-job job)
      (add-hook 'kill-buffer-hook #'gregorio-preview-abort nil t)
      (let ((master (plist-get settings :master)))
        (gregorio-preview--log "Master document: %s\n\n"
                               (or master "none"))
        (message "Generating %d preview%s%s..." n (if (= n 1) "" "s")
                 (if master
                     (format " (preamble of %s)" (file-name-nondirectory master))
                   "")))
      (gregorio-preview--run-sequence
       job (gregorio-preview--compile-steps job)
       (lambda () (gregorio-preview--typeset job))))))

;;; ---------------------------------------------------------------------------
;;; Commands
;;; ---------------------------------------------------------------------------

;;;###autoload
(defun gregorio-preview-region (beg end)
  "Preview the chant body lines between BEG and END."
  (interactive "r" gregorio-mode)
  (gregorio-preview--start beg end))

;;;###autoload
(defun gregorio-preview-buffer ()
  "Preview every line of the chant body."
  (interactive nil gregorio-mode)
  (gregorio-preview--start (point-min) (point-max)))

;;;###autoload
(defun gregorio-preview-toggle (&optional event)
  "Toggle between the preview image and the source at point.
When called from a mouse EVENT, act on the preview clicked on."
  (interactive (list last-nonmenu-event) gregorio-mode)
  (let* ((pos (if (mouse-event-p event)
                  (posn-point (event-start event))
                (point)))
         (ov (gregorio-preview--overlay-at pos)))
    (pcase (and ov (overlay-get ov 'gregorio-preview))
      ('shown (gregorio-preview--set-state ov 'revealed)
              (overlay-put ov 'gregorio-preview-auto nil))
      ('revealed (gregorio-preview--set-state ov 'shown))
      (_ (user-error "No preview here")))))

;;;###autoload
(defun gregorio-preview-at-point ()
  "Toggle the preview of the line at point, or generate it."
  (interactive nil gregorio-mode)
  (let ((ov (gregorio-preview--overlay-at (point))))
    (if (and ov (memq (overlay-get ov 'gregorio-preview) '(shown revealed)))
        (gregorio-preview-toggle)
      (gregorio-preview--start (line-beginning-position)
                               (line-end-position)))))

;;;###autoload
(defun gregorio-preview-clearout-region (beg end)
  "Remove the previews between BEG and END."
  (interactive "r" gregorio-mode)
  (mapc #'delete-overlay (gregorio-preview--overlays beg end)))

;;;###autoload
(defun gregorio-preview-clearout-buffer ()
  "Remove all previews in the buffer."
  (interactive nil gregorio-mode)
  (gregorio-preview-abort)
  (save-restriction
    (widen)
    (gregorio-preview-clearout-region (point-min) (point-max))))

;;;###autoload
(defun gregorio-preview-clearout-at-point ()
  "Remove the preview of the line at point."
  (interactive nil gregorio-mode)
  (let ((ov (gregorio-preview--overlay-at (point))))
    (if ov (delete-overlay ov) (user-error "No preview here"))))

;;;###autoload
(defun gregorio-preview-explain-error (&optional event)
  "Explain why the preview at point (or clicked on with EVENT) failed."
  (interactive (list last-nonmenu-event) gregorio-mode)
  (let* ((pos (if (mouse-event-p event)
                  (posn-point (event-start event))
                (point)))
         (ov (gregorio-preview--overlay-at pos))
         (message (and ov (overlay-get ov 'gregorio-preview-error)))
         (source (current-buffer))
         (master (gregorio-preview--master-file)))
    (unless (and message (eq (overlay-get ov 'gregorio-preview) 'error))
      (user-error "No preview error here"))
    (with-help-window "*gregorio-preview-error*"
      (with-current-buffer standard-output
        (insert (propertize "Preview error" 'face 'bold) "\n\n"
                message "\n\n")
        (insert "Master document: "
                (if master (abbreviate-file-name master) "none") "\n\n")
        (when (string-match-p "Undefined control sequence" message)
          (insert "The score uses LaTeX code from a package that the preview\n"
                  "document does not load.  Load it in the master document,\n"
                  "in `gregorio-preview-preamble' or in a file-local preamble.\n\n"))
        (insert-button "Show the LaTeX log"
                       'action (lambda (_)
                                 (pop-to-buffer gregorio-preview--log-buffer)))
        (insert "\n")
        (insert-button "Add a file-local preamble"
                       'action (lambda (_)
                                 (pop-to-buffer source)
                                 (call-interactively
                                  #'gregorio-preview-add-local-preamble)))
        (insert "\n")
        (insert-button "Customize gregorio-preview-preamble"
                       'action (lambda (_)
                                 (customize-variable
                                  'gregorio-preview-preamble)))
        (insert "\n")
        (if master
            (insert-button "Open the master document"
                           'action (lambda (_) (find-file-other-window master)))
          (insert-button "Customize gregorio-preview-master"
                         'action (lambda (_)
                                   (customize-variable
                                    'gregorio-preview-master))))
        (insert "\n")))))

;;;###autoload
(defun gregorio-preview-add-local-preamble (preamble)
  "Set PREAMBLE as the file-local value of `gregorio-preview-preamble'.
The value is written in a Local Variables block at the end of the
file and applied to the current buffer."
  (interactive
   (list (read-string "Preview preamble: "
                      (if (string-empty-p gregorio-preview-preamble)
                          "\\usepackage{}"
                        gregorio-preview-preamble)))
   gregorio-mode)
  (add-file-local-variable 'gregorio-preview-preamble preamble)
  (setq-local gregorio-preview-preamble preamble))

;;;###autoload
(defun gregorio-preview-abort ()
  "Abort the preview job running in the current buffer."
  (interactive nil gregorio-mode)
  (let ((job gregorio-preview--current-job))
    (when job
      (setq gregorio-preview--current-job nil)
      (let ((process (gregorio-preview--job-process job)))
        (when (process-live-p process)
          (delete-process process)))
      (dolist (chunk (gregorio-preview--job-chunks job))
        (let ((ov (car chunk)))
          (when (eq (overlay-get ov 'gregorio-preview) 'busy)
            (delete-overlay ov))))
      (gregorio-preview--cleanup job))))

(provide 'gregorio-preview)

;;; gregorio-preview.el ends here
