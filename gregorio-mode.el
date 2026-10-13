;;; gregorio-mode.el --- Major mode for GABC/NABC Gregorian chant notation -*- lexical-binding: t; -*-

;; Copyright (C) 2026 AISCGre Brasil

;; Author: AISCGre Brasil
;; URL: https://github.com/AISCGre-BR/gregorio-mode
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, music, tex
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; `gregorio-mode' is a major mode for editing GABC/NABC files, the
;; Gregorian chant notation used by Gregorio (https://gregorio-project.github.io).
;; It is the Emacs counterpart of gregorio.nvim, vscode-gregorio and
;; zed-gregorio, and provides:
;;
;; - Regex-based syntax highlighting for headers, clefs, pitches, neume
;;   shapes, alterations, rhythmic signs, bars, custos, line breaks,
;;   spacing, attributes, lyric markup tags and NABC (Saint Gall / Laon)
;;   notation.  GABC and NABC segments inside a note group are told apart
;;   using the `nabc-lines' header.
;; - Editing commands: shift notes up/down, fill empty note groups and
;;   convert ligatures to/from `<sp>' tags.
;; - Integration with the gregorio-lsp language server through Eglot
;;   (or lsp-mode), including document formatting.
;; - Templates, header skeletons and yasnippet snippets.
;; - Inline score previews, in the spirit of AUCTeX's preview-latex
;;   (gregorio-preview.el).
;;
;; A tree-sitter based variant, `gregorio-ts-mode', lives in
;; gregorio-ts-mode.el.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'skeleton)

(declare-function eglot-current-server "eglot")
(declare-function eglot-ensure "eglot")
(declare-function eglot-format-buffer "eglot")
(declare-function eglot-reconnect "eglot")
(declare-function eglot--major-modes "eglot")
(declare-function jsonrpc-notify "jsonrpc")
(declare-function lsp "lsp-mode")
(declare-function lsp-format-buffer "lsp-mode")
(declare-function lsp-workspace-restart "lsp-mode")
(declare-function lsp-workspaces "lsp-mode")
(declare-function lsp-register-client "lsp-mode")
(declare-function make-lsp-client "lsp-mode")
(declare-function lsp-stdio-connection "lsp-mode")
(declare-function lsp-activate-on "lsp-mode")
(declare-function lsp-notify "lsp-mode")
(declare-function yas-load-directory "yasnippet")
(defvar eglot-server-programs)
(defvar eglot-connect-hook)
(defvar lsp-mode)
(defvar lsp--cur-workspace)
(defvar lsp-language-id-configuration)
(defvar yas-snippet-dirs)

(defgroup gregorio nil
  "Support for GABC/NABC Gregorian chant notation."
  :group 'languages
  :prefix "gregorio-"
  :link '(url-link "https://github.com/AISCGre-BR/gregorio-mode"))

(defconst gregorio--root
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory where gregorio-mode is installed.")

;;; ---------------------------------------------------------------------------
;;; Customization
;;; ---------------------------------------------------------------------------

(defcustom gregorio-lsp-client 'eglot
  "LSP client used to start gregorio-lsp automatically.
When nil, the language server is not started automatically; it can
still be started manually with \\[eglot] or \\[lsp]."
  :type '(choice (const :tag "Eglot" eglot)
                 (const :tag "lsp-mode" lsp-mode)
                 (const :tag "Do not start automatically" nil)))

(defcustom gregorio-lsp-command '("gregorio-lsp")
  "Command (program and arguments) used to run the gregorio-lsp server."
  :type '(repeat string))

(defcustom gregorio-lsp-settings nil
  "Settings sent to gregorio-lsp through `workspace/didChangeConfiguration'.
A plist mirroring the server configuration, for example:

  (:linting (:enabled t :severity \"warning\" :ignoreRules [])
   :formatting (:maxLineWidth 80 :breakAfterClef :json-false
                :breakAfterBar :json-false))

When nil, nothing is sent and the server defaults apply."
  :type '(plist :key-type symbol :value-type sexp))

(defcustom gregorio-grefmt-command "grefmt"
  "Program used by `gregorio-format-buffer' when no LSP client is active."
  :type 'string)

(defcustom gregorio-grefmt-args nil
  "Extra arguments passed to `gregorio-grefmt-command'.
For example: (\"--width\" \"72\")."
  :type '(repeat string))

(defcustom gregorio-templates-directory
  (expand-file-name "templates" gregorio--root)
  "Directory holding the GABC templates offered by `gregorio-insert-template'."
  :type 'directory)

(defcustom gregorio-snippets-directory
  (expand-file-name "snippets" gregorio--root)
  "Directory holding the yasnippet snippets for `gregorio-mode'."
  :type 'directory)

;;; ---------------------------------------------------------------------------
;;; Faces
;;; ---------------------------------------------------------------------------

(defgroup gregorio-faces nil
  "Faces used by `gregorio-mode' and `gregorio-ts-mode'."
  :group 'gregorio
  :group 'faces)

(defmacro gregorio--defface (name parent doc)
  "Define face NAME inheriting from PARENT with documentation DOC."
  `(defface ,name '((t :inherit ,parent)) ,doc :group 'gregorio-faces))

(gregorio--defface gregorio-header-name-face font-lock-keyword-face
  "Face for header names (e.g. `name', `mode').")
(gregorio--defface gregorio-header-value-face font-lock-string-face
  "Face for header values.")
(gregorio--defface gregorio-separator-face font-lock-preprocessor-face
  "Face for the `%%' header/body separator.")
(gregorio--defface gregorio-delimiter-face font-lock-delimiter-face
  "Face for punctuation such as `:', `;' and `|'.")
(gregorio--defface gregorio-number-face font-lock-number-face
  "Face for numeric values and suffixes.")
(gregorio--defface gregorio-clef-face font-lock-keyword-face
  "Face for clefs (c1-c4, cb3, f3, ...).")
(gregorio--defface gregorio-pitch-face font-lock-constant-face
  "Face for GABC pitch letters.")
(gregorio--defface gregorio-shape-face font-lock-type-face
  "Face for neume shapes and liquescence (o, w, v, s, q, r, ~, <, >, ...).")
(gregorio--defface gregorio-alteration-face font-lock-operator-face
  "Face for alterations (flat, natural, sharp).")
(gregorio--defface gregorio-rhythm-face font-lock-variable-name-face
  "Face for rhythmic signs (punctum mora, episema, ictus).")
(gregorio--defface gregorio-bar-face font-lock-builtin-face
  "Face for divisiones (bars) and virgula.")
(gregorio--defface gregorio-custos-face font-lock-preprocessor-face
  "Face for custos.")
(gregorio--defface gregorio-line-break-face font-lock-preprocessor-face
  "Face for line breaks (z, Z).")
(gregorio--defface gregorio-spacing-face font-lock-delimiter-face
  "Face for spacing and fusion operators (/, //, !, @).")
(gregorio--defface gregorio-attribute-name-face font-lock-property-name-face
  "Face for note attribute names ([shape:...], [oh:...], ...).")
(gregorio--defface gregorio-attribute-value-face font-lock-string-face
  "Face for note attribute values.")
(gregorio--defface gregorio-macro-face font-lock-preprocessor-face
  "Face for macro references ([nm1], [gm2], ...) and [nocustos].")
(gregorio--defface gregorio-nabc-neume-face font-lock-function-name-face
  "Face for NABC neume codes (vi, pu, ta, cl, pe, ...).")
(gregorio--defface gregorio-nabc-modifier-face font-lock-operator-face
  "Face for NABC glyph modifiers (S, G, M, -, >, ~).")
(gregorio--defface gregorio-nabc-pitch-face font-lock-constant-face
  "Face for NABC pitch descriptors (hf, hg, ...).")
(gregorio--defface gregorio-nabc-letter-face font-lock-variable-use-face
  "Face for NABC significant and Tironian letters.")
(gregorio--defface gregorio-tag-face font-lock-function-call-face
  "Face for lyric markup tags (<b>, <i>, <sp>, ...).")
(gregorio--defface gregorio-verbatim-face font-lock-doc-markup-face
  "Face for verbatim TeX code (<v>...</v>, [nv:...], ...).")
(gregorio--defface gregorio-special-char-face font-lock-escape-face
  "Face for special characters (<sp>...</sp>) and $ escapes.")
(gregorio--defface gregorio-translation-face font-lock-doc-face
  "Face for translations ([...] outside note groups).")
(gregorio--defface gregorio-centering-face font-lock-bracket-face
  "Face for lyric centering braces and lyric ties.")
(gregorio--defface gregorio-asterisk-face font-lock-keyword-face
  "Face for asterisks in the lyrics.")
(gregorio--defface gregorio-error-face font-lock-warning-face
  "Face for characters that are invalid in a note group.")

(defface gregorio-bold-face '((t :weight bold))
  "Face for text inside <b>...</b>." :group 'gregorio-faces)
(defface gregorio-italic-face '((t :slant italic))
  "Face for text inside <i>...</i> and <e>...</e>." :group 'gregorio-faces)
(defface gregorio-underline-face '((t :underline t))
  "Face for text inside <ul>...</ul>." :group 'gregorio-faces)
(defface gregorio-small-caps-face '((t :height 0.9 :weight semi-bold))
  "Face for text inside <sc>...</sc>." :group 'gregorio-faces)
(defface gregorio-teletype-face '((t :inherit fixed-pitch))
  "Face for text inside <tt>...</tt>." :group 'gregorio-faces)
(defface gregorio-colored-face
  '((((class color) (background light)) :foreground "red3")
    (((class color) (background dark)) :foreground "IndianRed1")
    (t :inherit font-lock-warning-face))
  "Face for text inside <c>...</c> (rubrics)." :group 'gregorio-faces)

;;; ---------------------------------------------------------------------------
;;; Document structure: separator, body and nabc-lines
;;; ---------------------------------------------------------------------------

(defconst gregorio--separator-regexp "^%%[ \t]*$"
  "Regexp matching the header/body separator line.")

(defvar-local gregorio--structure-cache nil
  "Cache of (TICK SEPARATOR-START BODY-START NABC-LINES).")

(defun gregorio--structure ()
  "Return (SEPARATOR-START BODY-START NABC-LINES) for the current buffer.
SEPARATOR-START and BODY-START are nil when there is no `%%' line."
  (let ((tick (buffer-chars-modified-tick)))
    (unless (eq (car gregorio--structure-cache) tick)
      (setq gregorio--structure-cache
            (cons tick
                  (save-excursion
                    (save-restriction
                      (widen)
                      (goto-char (point-min))
                      (let* ((case-fold-search nil)
                             (sep (and (re-search-forward
                                        gregorio--separator-regexp nil t)
                                       (match-beginning 0)))
                             (body (and sep (min (point-max) (1+ (point)))))
                             (nabc 0))
                        (goto-char (point-min))
                        (when (let ((case-fold-search t))
                                (re-search-forward
                                 "^[ \t]*nabc-lines[ \t]*:[ \t]*\\([0-9]+\\)"
                                 sep t))
                          (setq nabc (string-to-number (match-string 1))))
                        (list sep body nabc)))))))
    (cdr gregorio--structure-cache)))

(defun gregorio--separator-start ()
  "Return the position of the `%%' separator line, or nil."
  (nth 0 (gregorio--structure)))

(defun gregorio--body-start ()
  "Return the position of the first character of the body, or nil."
  (nth 1 (gregorio--structure)))

(defun gregorio-nabc-lines ()
  "Return the value of the `nabc-lines' header, or 0 when absent."
  (nth 2 (gregorio--structure)))

(defun gregorio--gabc-segment-p (segment nabc-lines)
  "Return non-nil when SEGMENT (0-based) of a note group is GABC.
In a group (s0|s1|...|sN), segment i is GABC when
i mod (NABC-LINES + 1) = 0.  Without `nabc-lines', only s0 is GABC."
  (if (zerop nabc-lines)
      (zerop segment)
    (zerop (% segment (1+ nabc-lines)))))

(defun gregorio--context (pos)
  "Return the lexical context at POS.
One of the symbols `header', `separator', `comment', `lyric', `gabc',
`nabc' or `attribute' (inside a [...] attribute of a GABC segment)."
  (pcase-let ((`(,sep ,body ,nabc) (gregorio--structure)))
    (cond
     ((or (null sep) (< pos sep)) 'header)
     ((< pos body) 'separator)
     (t
      (save-excursion
        (goto-char pos)
        (let ((i (max body (line-beginning-position)))
              (in-group nil) (segment 0) (depth 0) (fusion nil)
              (result nil))
          (while (and (not result) (< i pos))
            (let ((c (char-after i)))
              (cond
               ((and (eq c ?%) (not (eq (char-before i) ?$)))
                (setq result 'comment))
               ((not in-group)
                (cond ((eq c ?\() (setq in-group t segment 0 depth 0
                                        fusion nil))
                      ((eq c ?$) (setq i (1+ i)))))
               ((> depth 0)
                (cond ((eq c ?\[) (setq depth (1+ depth)))
                      ((eq c ?\]) (setq depth (1- depth)))))
               ((eq c ?\)) (setq in-group nil))
               ((eq c ?|) (setq segment (1+ segment)))
               ((eq c ?\[)
                (if (eq (char-before i) ?@) (setq fusion t) (setq depth 1)))
               ((and fusion (eq c ?\])) (setq fusion nil))))
            (setq i (1+ i)))
          (cond (result)
                ((not in-group) 'lyric)
                ((> depth 0) 'attribute)
                ((gregorio--gabc-segment-p segment nabc) 'gabc)
                (t 'nabc))))))))

;;; ---------------------------------------------------------------------------
;;; Font lock
;;; ---------------------------------------------------------------------------

(defun gregorio--matcher (regexp contexts &optional subexp)
  "Return a font-lock matcher for REGEXP restricted to CONTEXTS.
The context is checked at the start of SUBEXP (default 0)."
  (lambda (limit)
    (let ((case-fold-search nil) found)
      (while (and (not found) (re-search-forward regexp limit t))
        (when (memq (save-match-data
                      (gregorio--context (match-beginning (or subexp 0))))
                    contexts)
          (setq found t)))
      found)))

(defconst gregorio--nabc-neumes
  '("vi" "pu" "ta" "gr" "cl" "pe" "po" "to" "ci" "sc" "pf" "sf" "tr" "st"
    "ds" "ts" "tg" "bv" "tv" "pq" "pr" "pi" "vs" "or" "sa" "ql" "qi" "pt"
    "ni" "oc" "un")
  "NABC basic glyph descriptors.")

(defconst gregorio--style-tags
  '(("b" . gregorio-bold-face)
    ("i" . gregorio-italic-face)
    ("e" . gregorio-italic-face)
    ("ul" . gregorio-underline-face)
    ("sc" . gregorio-small-caps-face)
    ("tt" . gregorio-teletype-face)
    ("c" . gregorio-colored-face))
  "Lyric style tags and the face applied to their contents.")

(defun gregorio--fontify-style-spans (limit)
  "Apply style faces to lyric text inside style tags up to LIMIT.
Only lyric characters are styled; note groups and tags are left alone.
Always returns nil: fontification is done as a side effect."
  (let ((case-fold-search nil)
        (re (concat "<\\(" (regexp-opt (mapcar #'car gregorio--style-tags))
                    "\\)>")))
    (while (re-search-forward re limit t)
      (when (eq (save-match-data (gregorio--context (match-beginning 0)))
                'lyric)
        (let* ((tag (match-string-no-properties 1))
               (face (cdr (assoc tag gregorio--style-tags)))
               (start (point))
               (end (save-excursion
                      (if (search-forward (concat "</" tag ">")
                                          (line-end-position) t)
                          (match-beginning 0)
                        (line-end-position))))
               (i start) (in-group nil) (in-tag nil))
          (while (< i end)
            (let ((c (char-after i)))
              (cond ((eq c ?%) (setq i end))
                    (in-group (when (eq c ?\)) (setq in-group nil)))
                    (in-tag (when (eq c ?>) (setq in-tag nil)))
                    ((eq c ?\() (setq in-group t))
                    ((eq c ?<) (setq in-tag t))
                    (t (font-lock-append-text-property
                        i (1+ i) 'face face))))
            (setq i (1+ i)))))))
  nil)

(defconst gregorio-font-lock-keywords
  (let ((body '(lyric gabc nabc attribute)))
    `(
      ;; ---------------------------------------------------------------- header
      (,gregorio--separator-regexp . 'gregorio-separator-face)
      (,(gregorio--matcher
         "^[ \t]*\\(mode\\|staff-lines\\|nabc-lines\\|initial-style\\)[ \t]*\\(:\\)[ \t]*\\([0-9]+\\)"
         '(header))
       (1 'gregorio-header-name-face) (2 'gregorio-delimiter-face)
       (3 'gregorio-number-face))
      (,(gregorio--matcher "<v>\\(.*?\\)</v>" '(header))
       (0 'gregorio-tag-face) (1 'gregorio-verbatim-face t))
      (,(gregorio--matcher "\\\\[A-Za-z@]+" '(header))
       (0 'gregorio-verbatim-face))
      (,(gregorio--matcher
         "^[ \t]*\\([A-Za-z][A-Za-z0-9_-]*\\)[ \t]*\\(:\\)[ \t]*\\([^;\n]*\\)\\(;*\\)"
         '(header))
       (1 'gregorio-header-name-face) (2 'gregorio-delimiter-face)
       (3 'gregorio-header-value-face keep) (4 'gregorio-delimiter-face))

      ;; ------------------------------------------------------------- lyrics
      (,(gregorio--matcher "<v>\\(.*?\\)</v>" '(lyric))
       (1 'gregorio-verbatim-face))
      (,(gregorio--matcher "<sp>\\([^<\n]*\\)</sp>" '(lyric))
       (1 'gregorio-special-char-face))
      (,(gregorio--matcher "<alt>\\([^<\n]*\\)</alt>" '(lyric))
       (1 'gregorio-attribute-value-face))
      (,(gregorio--matcher
         "</?\\(?:b\\|i\\|c\\|sc\\|tt\\|ul\\|clear\\|e\\|eu\\|nlba\\|alt\\|sp\\|v\\|pr\\(?::[.0-9]+\\)?\\)>"
         '(lyric))
       . 'gregorio-tag-face)
      (gregorio--fontify-style-spans)
      (,(gregorio--matcher "\\$." '(lyric)) . 'gregorio-special-char-face)
      (,(gregorio--matcher "\\[[^]\n]*\\]" '(lyric))
       . 'gregorio-translation-face)
      (,(gregorio--matcher "[{}~]" '(lyric)) . 'gregorio-centering-face)
      (,(gregorio--matcher "\\*+" '(lyric)) . 'gregorio-asterisk-face)

      ;; ------------------------------------------------------- note groups
      ;; Clefs: c1-c5, cb1-cb5, f1-f5, optionally linked with @.
      (,(gregorio--matcher
         "[^A-Za-z]\\(\\(?:cb\\|[cf]\\)[1-5]\\(?:@\\(?:cb\\|[cf]\\)[1-5]\\)?\\)"
         '(gabc) 1)
       (1 'gregorio-clef-face))
      ;; Attributes: [name:value], macros and [nocustos].
      (,(gregorio--matcher "/\\[-?[0-9.]+\\]" '(gabc))
       . 'gregorio-spacing-face)
      (,(gregorio--matcher "\\[\\(nocustos\\|\\(?:alt\\|[nge]\\)m[0-9]\\)\\]"
                           '(gabc))
       . 'gregorio-macro-face)
      (,(gregorio--matcher "\\[\\([nge]v\\)\\(:\\)\\([^]\n]*\\)\\]" '(gabc))
       (0 'gregorio-delimiter-face) (1 'gregorio-attribute-name-face t)
       (3 'gregorio-verbatim-face t))
      (,(gregorio--matcher "\\[\\([a-z]+\\)\\(:\\)\\([^]\n]*\\)\\]" '(gabc))
       (0 'gregorio-delimiter-face) (1 'gregorio-attribute-name-face t)
       (3 'gregorio-attribute-value-face t))
      ;; Custos (f+) and automatic custos / line breaks (z0, z, Z, z+, Z-).
      (,(gregorio--matcher "[a-np]\\+" '(gabc)) . 'gregorio-custos-face)
      (,(gregorio--matcher "z0" '(gabc)) . 'gregorio-custos-face)
      (,(gregorio--matcher "[zZ][-+]?" '(gabc)) . 'gregorio-line-break-face)
      ;; Alterations: x y # X Y ## and parenthesized variants.
      (,(gregorio--matcher "[a-np]\\(##\\|[xy#]\\??\\|[XY]\\)" '(gabc))
       (1 'gregorio-alteration-face))
      ;; Bars.
      (,(gregorio--matcher "::\\|:[?']?\\|;[1-8]?\\|[,^`][0']?" '(gabc))
       . 'gregorio-bar-face)
      ;; Spacing and fusion.
      (,(gregorio--matcher "//\\|/[0!]?\\|!\\|@\\[?" '(gabc))
       . 'gregorio-spacing-face)
      ;; Initio debilis, shapes and liquescence.
      (,(gregorio--matcher "\\(-\\)[a-npA-NP]" '(gabc))
       (1 'gregorio-shape-face))
      (,(gregorio--matcher "r[0-8]\\|[oOwWvVsqQ~<>=rR][01]?" '(gabc))
       . 'gregorio-shape-face)
      ;; Rhythmic signs: punctum mora, episema, ictus.
      (,(gregorio--matcher "\\.\\{1,2\\}[01]?\\|_[0-5]*\\|'[01]?" '(gabc))
       . 'gregorio-rhythm-face)
      ;; Pitches (uppercase pitches may take a 0/1/2 leaning suffix).
      (,(gregorio--matcher "[A-NP]\\([012]\\)" '(gabc))
       (1 'gregorio-number-face))
      (,(gregorio--matcher "[a-npA-NP]" '(gabc)) . 'gregorio-pitch-face)
      (,(gregorio--matcher "[$&\\]" '(gabc)) . 'gregorio-error-face)

      ;; -------------------------------------------------------------- NABC
      (,(gregorio--matcher "\\(l[st]\\)\\([a-z-]+?\\)\\([1-9]\\)" '(nabc))
       (1 'gregorio-nabc-letter-face) (2 'gregorio-nabc-letter-face)
       (3 'gregorio-number-face))
      (,(gregorio--matcher "\\(su\\|pp\\)\\([tuvwxynqz]?\\)\\([1-9]\\)" '(nabc))
       (1 'gregorio-shape-face) (2 'gregorio-nabc-modifier-face)
       (3 'gregorio-number-face))
      (,(gregorio--matcher "\\(h\\)\\([a-np]\\)" '(nabc))
       (1 'gregorio-nabc-modifier-face) (2 'gregorio-nabc-pitch-face))
      (,(gregorio--matcher (regexp-opt gregorio--nabc-neumes) '(nabc))
       . 'gregorio-nabc-neume-face)
      (,(gregorio--matcher "\\([SGM>~-]\\)\\([1-9]?\\)" '(nabc))
       (1 'gregorio-nabc-modifier-face) (2 'gregorio-number-face))
      (,(gregorio--matcher "[!/`]+" '(nabc)) . 'gregorio-spacing-face)
      (,(gregorio--matcher "[0-9]+" '(nabc)) . 'gregorio-number-face)

      ;; ------------------------------------------------- group delimiters
      (,(gregorio--matcher "|" '(gabc nabc)) . 'gregorio-delimiter-face)
      (,(gregorio--matcher "[0-9]+" '(gabc)) . 'gregorio-number-face)
      (,(gregorio--matcher "[()]" body) . 'font-lock-bracket-face)))
  "Font-lock keywords for `gregorio-mode'.")

(defvar-local gregorio--fontification-key nil
  "Separator position and `nabc-lines' value used for the last fontification.")

(defun gregorio--after-change (&rest _)
  "Refontify the buffer when the separator or `nabc-lines' changes."
  (let ((key (list (gregorio--separator-start) (gregorio-nabc-lines))))
    (unless (equal key gregorio--fontification-key)
      (setq gregorio--fontification-key key)
      (font-lock-flush))))

;;; ---------------------------------------------------------------------------
;;; Syntax
;;; ---------------------------------------------------------------------------

(defvar gregorio-mode-syntax-table
  (let ((table (make-syntax-table)))
    (modify-syntax-entry ?% "<" table)
    (modify-syntax-entry ?\n ">" table)
    (modify-syntax-entry ?$ "\\" table)
    (modify-syntax-entry ?\( "()" table)
    (modify-syntax-entry ?\) ")(" table)
    (modify-syntax-entry ?\[ "(]" table)
    (modify-syntax-entry ?\] ")[" table)
    (modify-syntax-entry ?{ "(}" table)
    (modify-syntax-entry ?} "){" table)
    (dolist (c '(?< ?> ?\" ?' ?| ?/ ?! ?@ ?: ?\; ?, ?^ ?` ?_ ?. ?~ ?= ?+ ?- ?# ?*))
      (modify-syntax-entry c "." table))
    table)
  "Syntax table for `gregorio-mode'.")

(defconst gregorio--syntax-propertize
  (syntax-propertize-rules
   ;; The %% separator is not a comment.
   ("^\\(%\\)\\(%\\)[ \t]*$" (1 ".") (2 ".")))
  "Syntax propertize function for `gregorio-mode'.")

;;; ---------------------------------------------------------------------------
;;; Imenu
;;; ---------------------------------------------------------------------------

(defun gregorio-imenu-create-index ()
  "Return an imenu index of the headers and the body of a GABC buffer."
  (let ((sep (gregorio--separator-start))
        (case-fold-search nil)
        index)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "^[ \t]*\\([A-Za-z][A-Za-z0-9_-]*\\)[ \t]*:"
                                sep t)
        (push (cons (match-string-no-properties 1) (match-beginning 1))
              index)))
    (setq index (nreverse index))
    (if sep (append index (list (cons "%% (body)" sep))) index)))

;;; ---------------------------------------------------------------------------
;;; Note groups
;;; ---------------------------------------------------------------------------

(defconst gregorio--pitches "abcdefghijklmnp"
  "GABC pitches in ascending order.  `o' is not a pitch.")

(defun gregorio--pitch-char-p (c)
  "Return non-nil if character C is a GABC pitch letter."
  (and c (or (and (>= c ?a) (<= c ?n)) (eq c ?p)
             (and (>= c ?A) (<= c ?N)) (eq c ?P))))

(defun gregorio-shift-pitch (c steps)
  "Return pitch character C shifted by STEPS, wrapping cyclically.
Case is preserved; non-pitch characters are returned unchanged."
  (let* ((upper (and (>= c ?A) (<= c ?Z)))
         (index (cl-position (downcase c) gregorio--pitches)))
    (if (not (gregorio--pitch-char-p c))
        c
      (let ((new (aref gregorio--pitches
                       (mod (+ index steps) (length gregorio--pitches)))))
        (if upper (upcase new) new)))))

(defun gregorio--body-groups ()
  "Return a list of (OPEN . CLOSE) positions for each note group in the body.
OPEN is the position of `(' and CLOSE the position of `)'.  Comments,
escaped characters and <v>...</v> verbatim text are skipped."
  (let ((start (gregorio--body-start))
        (case-fold-search nil)
        groups)
    (when start
      (save-excursion
        (save-restriction
          (widen)
          (goto-char start)
          (while (re-search-forward "[%($<]" nil t)
            (pcase (char-before)
              (?% (forward-line 1))
              (?$ (unless (eobp) (forward-char 1)))
              (?< (when (looking-at "v>")
                    (unless (search-forward "</v>" nil t)
                      (goto-char (point-max)))))
              (?\( (let ((open (1- (point))))
                     (if (search-forward ")" nil t)
                         (push (cons open (1- (point))) groups)
                       (goto-char (point-max))))))))))
    (nreverse groups)))

(defun gregorio--clef-group-p (open close)
  "Return non-nil if the group between OPEN and CLOSE starts with a clef."
  (save-excursion
    (goto-char (1+ open))
    (let ((case-fold-search nil))
      (and (re-search-forward "\\=[ \t]*\\(?:cb\\|[cf]\\)[1-5]" close t) t))))

(defun gregorio--empty-group-p (open close)
  "Return non-nil if the group between OPEN and CLOSE is blank."
  (save-excursion
    (goto-char (1+ open))
    (skip-chars-forward " \t\n" close)
    (>= (point) close)))

(defun gregorio--group-pitches (open close nabc-lines)
  "Return positions of GABC pitch letters in the group from OPEN to CLOSE.
Clef groups, NABC segments (according to NABC-LINES) and bracketed
attributes such as [nv:...] are excluded; fusions @[...] are included."
  (unless (gregorio--clef-group-p open close)
    (let ((pos (1+ open)) (segment 0) (depth 0) result)
      (while (< pos close)
        (let ((c (char-after pos)))
          (cond
           ((> depth 0)
            (cond ((eq c ?\[) (setq depth (1+ depth)))
                  ((eq c ?\]) (setq depth (1- depth)))))
           ((eq c ?|) (setq segment (1+ segment)))
           ((eq c ?\[) (unless (eq (char-before pos) ?@) (setq depth 1)))
           ((and (gregorio--gabc-segment-p segment nabc-lines)
                 (gregorio--pitch-char-p c))
            (push pos result))))
        (setq pos (1+ pos)))
      (nreverse result))))

;;; ---------------------------------------------------------------------------
;;; Editing commands
;;; ---------------------------------------------------------------------------

(defun gregorio--require-body ()
  "Signal a `user-error' unless the buffer has a `%%' separator."
  (unless (gregorio--body-start)
    (user-error "No `%%%%' header/body separator found")))

(defun gregorio--in-range-p (pos beg end)
  "Return non-nil if POS is within [BEG, END), or when BEG is nil."
  (or (null beg) (and (>= pos beg) (< pos end))))

(defun gregorio--region-args ()
  "Return (BEG END) for the active region, or (nil nil)."
  (if (use-region-p)
      (list (region-beginning) (region-end))
    (list nil nil)))

(defun gregorio-shift-notes (steps &optional beg end)
  "Shift GABC pitch letters in the body by STEPS diatonic degrees.
Positive STEPS shift up, negative shift down, wrapping cyclically
\(... n p a b ...).  When BEG and END are non-nil, only pitches in that
range are shifted.  Headers, lyrics, clefs, comments, attributes and NABC
segments (per `nabc-lines') are never modified.  Return the number of
shifted pitches."
  (gregorio--require-body)
  (let ((nabc (gregorio-nabc-lines))
        (count 0))
    (save-excursion
      (dolist (group (gregorio--body-groups))
        (dolist (pos (gregorio--group-pitches (car group) (cdr group) nabc))
          (when (gregorio--in-range-p pos beg end)
            (goto-char pos)
            (let ((new (gregorio-shift-pitch (char-after pos) steps)))
              (unless (eq new (char-after pos))
                (delete-char 1)
                (insert-char new)
                (setq count (1+ count))))))))
    count))

(defun gregorio-note-shift-up (&optional n beg end)
  "Shift notes up by N steps (default 1) in the region or the whole body.
When BEG and END are non-nil, only pitches between them are shifted.
Interactively, N is the prefix argument and the region, when active,
provides BEG and END.  The region stays active so that the command can be
repeated."
  (interactive (cons (prefix-numeric-value current-prefix-arg)
                     (gregorio--region-args)))
  (let ((count (gregorio-shift-notes (or n 1) beg end)))
    (setq deactivate-mark nil)
    (message "Shifted %d note%s" count (if (= count 1) "" "s"))))

(defun gregorio-note-shift-down (&optional n beg end)
  "Shift notes down by N steps (default 1) in the region or the whole body.
BEG and END limit the operation as in `gregorio-note-shift-up'."
  (interactive (cons (prefix-numeric-value current-prefix-arg)
                     (gregorio--region-args)))
  (gregorio-note-shift-up (- (or n 1)) beg end))

(defun gregorio-fill-parens (&optional beg end)
  "Fill empty note groups with the last pitch of the preceding group.
For example, (fgh) () () (ij) () becomes (fgh) (h) (h) (ij) (j).  The
pitch is tracked across the whole body; when BEG and END are non-nil
\(interactively, the active region) only empty groups whose opening
parenthesis lies in that range are filled.  Return the number of filled
groups."
  (interactive (gregorio--region-args))
  (gregorio--require-body)
  (let ((nabc (gregorio-nabc-lines))
        last fills)
    (dolist (group (gregorio--body-groups))
      (let ((open (car group)) (close (cdr group)))
        (cond
         ((gregorio--clef-group-p open close))
         ((gregorio--empty-group-p open close)
          (when (and last (gregorio--in-range-p open beg end))
            (push (list open close last) fills)))
         (t
          (let ((pitches (gregorio--group-pitches open close nabc)))
            (when pitches
              (setq last (char-after (car (last pitches))))))))))
    ;; FILLS is in reverse buffer order, so positions stay valid.
    (save-excursion
      (pcase-dolist (`(,open ,close ,pitch) fills)
        (delete-region (1+ open) close)
        (goto-char (1+ open))
        (insert-char pitch)))
    (when (called-interactively-p 'interactive)
      (message "Filled %d group%s" (length fills)
               (if (= (length fills) 1) "" "s")))
    (length fills)))

(defconst gregorio--ligatures
  '(("æ" . "<sp>ae</sp>")
    ("ǽ" . "<sp>'ae</sp>")
    ("œ" . "<sp>oe</sp>"))
  "Unicode ligatures and their `<sp>' tag equivalents.")

(defun gregorio--replace-in-body (pairs beg end)
  "Replace each (FROM . TO) of PAIRS literally in the body.
When BEG and END are non-nil, restrict to that range (clamped to the
body).  Return the number of replacements."
  (gregorio--require-body)
  (let* ((body (gregorio--body-start))
         (beg (max (or beg body) body))
         (end (copy-marker (or end (point-max))))
         (case-fold-search nil)
         (count 0))
    (save-excursion
      (pcase-dolist (`(,from . ,to) pairs)
        (goto-char beg)
        (while (search-forward from end t)
          (replace-match to t t)
          (setq count (1+ count)))))
    (set-marker end nil)
    count))

(defun gregorio-convert-ligatures-to-tags (&optional beg end)
  "Convert æ, ǽ and œ into <sp> tags in the body.
When BEG and END are non-nil (interactively, the active region), only
that part of the body is converted.  Return the number of conversions."
  (interactive (gregorio--region-args))
  (let ((count (gregorio--replace-in-body gregorio--ligatures beg end)))
    (when (called-interactively-p 'interactive)
      (message "Converted %d ligature%s" count (if (= count 1) "" "s")))
    count))

(defun gregorio-convert-tags-to-ligatures (&optional beg end)
  "Convert <sp> ligature tags into æ, ǽ and œ in the body.
When BEG and END are non-nil (interactively, the active region), only
that part of the body is converted.  Return the number of conversions."
  (interactive (gregorio--region-args))
  (let ((count (gregorio--replace-in-body
                (mapcar (lambda (p) (cons (cdr p) (car p))) gregorio--ligatures)
                beg end)))
    (when (called-interactively-p 'interactive)
      (message "Converted %d tag%s" count (if (= count 1) "" "s")))
    count))

;;; ---------------------------------------------------------------------------
;;; Templates and skeletons
;;; ---------------------------------------------------------------------------

(defun gregorio-insert-template (file)
  "Insert the GABC template FILE from `gregorio-templates-directory'."
  (interactive
   (list (expand-file-name
          (completing-read
           "Template: "
           (directory-files gregorio-templates-directory nil "\\.gabc\\'")
           nil t)
          gregorio-templates-directory)))
  (insert-file-contents file))

(define-skeleton gregorio-insert-header
  "Insert a basic GABC header followed by the `%%' separator."
  nil
  "name: " (skeleton-read "Name: " "Chant Name") ";\n"
  "office-part: " (skeleton-read "Office part: " "antiphona") ";\n"
  "mode: " (skeleton-read "Mode: " "1") ";\n"
  "annotation: " (skeleton-read "Annotation: " "I") ";\n"
  "book: " (skeleton-read "Book: " "Graduale Romanum") ";\n"
  "transcriber: " (skeleton-read "Transcriber: " user-full-name) ";\n"
  "%%\n"
  "(" (skeleton-read "Clef: " "c4") ") " _)

(define-skeleton gregorio-insert-nabc-header
  "Insert a GABC header with `nabc-lines' followed by the `%%' separator."
  nil
  "name: " (skeleton-read "Name: " "Chant Name") ";\n"
  "office-part: " (skeleton-read "Office part: " "antiphona") ";\n"
  "mode: " (skeleton-read "Mode: " "1") ";\n"
  "annotation: " (skeleton-read "Annotation: " "I") ";\n"
  "nabc-lines: " (skeleton-read "NABC lines: " "1") ";\n"
  "book: " (skeleton-read "Book: " "St. Gall Manuscripts") ";\n"
  "transcriber: " (skeleton-read "Transcriber: " user-full-name) ";\n"
  "%%\n"
  "(" (skeleton-read "Clef: " "c4") ") " _)

(defun gregorio--yasnippet-setup ()
  "Register the bundled snippets with yasnippet."
  (when (file-directory-p gregorio-snippets-directory)
    (add-to-list 'yas-snippet-dirs gregorio-snippets-directory t)
    (yas-load-directory gregorio-snippets-directory)))

(with-eval-after-load 'yasnippet
  (gregorio--yasnippet-setup))

;;; ---------------------------------------------------------------------------
;;; Language server
;;; ---------------------------------------------------------------------------

(defun gregorio--eglot-send-settings (server)
  "Send `gregorio-lsp-settings' to SERVER when it serves GABC buffers."
  (when (and gregorio-lsp-settings
             (cl-intersection '(gregorio-mode gregorio-ts-mode)
                              (ensure-list (eglot--major-modes server))))
    (jsonrpc-notify server :workspace/didChangeConfiguration
                    (list :settings gregorio-lsp-settings))))

(with-eval-after-load 'eglot
  (add-to-list 'eglot-server-programs
               `(((gregorio-mode :language-id "gabc")
                  (gregorio-ts-mode :language-id "gabc"))
                 . ,(lambda (&rest _) gregorio-lsp-command)))
  (add-hook 'eglot-connect-hook #'gregorio--eglot-send-settings))

(with-eval-after-load 'lsp-mode
  (add-to-list 'lsp-language-id-configuration '(gregorio-mode . "gabc"))
  (add-to-list 'lsp-language-id-configuration '(gregorio-ts-mode . "gabc"))
  (lsp-register-client
   (make-lsp-client
    :new-connection (lsp-stdio-connection (lambda () gregorio-lsp-command))
    :activation-fn (lsp-activate-on "gabc")
    :initialized-fn (lambda (workspace)
                      (when gregorio-lsp-settings
                        (let ((lsp--cur-workspace workspace))
                          (lsp-notify "workspace/didChangeConfiguration"
                                      (list :settings gregorio-lsp-settings)))))
    :server-id 'gregorio-lsp)))

(defun gregorio--maybe-start-lsp ()
  "Start the language server according to `gregorio-lsp-client'."
  (when (and buffer-file-name
             (executable-find (car gregorio-lsp-command)))
    (pcase gregorio-lsp-client
      ('eglot (when (require 'eglot nil t) (eglot-ensure)))
      ('lsp-mode (when (require 'lsp-mode nil t) (lsp))))))

(defun gregorio-restart-language-server ()
  "Restart the gregorio-lsp server of the current buffer."
  (interactive)
  (cond
   ((and (fboundp 'eglot-current-server) (eglot-current-server))
    (eglot-reconnect (eglot-current-server)))
   ((bound-and-true-p lsp-mode)
    (mapc #'lsp-workspace-restart (lsp-workspaces)))
   (t (gregorio--maybe-start-lsp))))

(defun gregorio-format-buffer ()
  "Format the buffer with gregorio-lsp or, without a server, with grefmt."
  (interactive)
  (cond
   ((and (fboundp 'eglot-current-server) (eglot-current-server))
    (eglot-format-buffer))
   ((bound-and-true-p lsp-mode) (lsp-format-buffer))
   ((executable-find gregorio-grefmt-command)
    (let ((out (generate-new-buffer " *grefmt*"))
          (err (make-temp-file "grefmt")))
      (unwind-protect
          (if (zerop (apply #'call-process-region (point-min) (point-max)
                            gregorio-grefmt-command nil (list out err) nil
                            gregorio-grefmt-args))
              (with-no-warnings (replace-buffer-contents out))
            (user-error "Grefmt failed: %s"
                        (with-temp-buffer
                          (insert-file-contents err)
                          (string-trim (buffer-string)))))
        (kill-buffer out)
        (delete-file err))))
   (t (user-error "Neither gregorio-lsp nor %s is available"
                  gregorio-grefmt-command))))

;;; ---------------------------------------------------------------------------
;;; Keymap and menu
;;; ---------------------------------------------------------------------------

;; Score previews live in gregorio-preview.el, loaded on first use.
(autoload 'gregorio-preview-at-point "gregorio-preview" nil t)
(autoload 'gregorio-preview-region "gregorio-preview" nil t)
(autoload 'gregorio-preview-buffer "gregorio-preview" nil t)
(autoload 'gregorio-preview-toggle "gregorio-preview" nil t)
(autoload 'gregorio-preview-clearout-at-point "gregorio-preview" nil t)
(autoload 'gregorio-preview-clearout-region "gregorio-preview" nil t)
(autoload 'gregorio-preview-clearout-buffer "gregorio-preview" nil t)
(autoload 'gregorio-preview-abort "gregorio-preview" nil t)

(defvar-keymap gregorio-preview-map
  :doc "Keymap for score preview commands, bound to \`C-c C-p'."
  "C-p" #'gregorio-preview-at-point
  "C-r" #'gregorio-preview-region
  "C-b" #'gregorio-preview-buffer
  "C-k" #'gregorio-preview-abort
  "C-c C-p" #'gregorio-preview-clearout-at-point
  "C-c C-r" #'gregorio-preview-clearout-region
  "C-c C-b" #'gregorio-preview-clearout-buffer)

(defvar-keymap gregorio-mode-map
  :doc "Keymap for `gregorio-mode'."
  "C-c C-u" #'gregorio-note-shift-up
  "C-c C-d" #'gregorio-note-shift-down
  "C-c C-f" #'gregorio-fill-parens
  "C-c C-l" #'gregorio-convert-ligatures-to-tags
  "C-c C-t" #'gregorio-convert-tags-to-ligatures
  "C-c C-r" #'gregorio-format-buffer
  "C-c C-i" #'gregorio-insert-template
  "C-c C-p" gregorio-preview-map)

(defvar-keymap gregorio-shift-repeat-map
  :doc "Repeat map for shifting notes; see `repeat-mode'."
  :repeat t
  "u" #'gregorio-note-shift-up
  "d" #'gregorio-note-shift-down)

(easy-menu-define gregorio-mode-menu gregorio-mode-map
  "Menu for `gregorio-mode'."
  '("Gregorio"
    ["Shift Notes Up" gregorio-note-shift-up]
    ["Shift Notes Down" gregorio-note-shift-down]
    ["Fill Empty Note Groups" gregorio-fill-parens]
    "---"
    ["Convert Ligatures to <sp> Tags" gregorio-convert-ligatures-to-tags]
    ["Convert <sp> Tags to Ligatures" gregorio-convert-tags-to-ligatures]
    "---"
    ["Insert Template..." gregorio-insert-template]
    ["Insert Header" gregorio-insert-header]
    ["Insert NABC Header" gregorio-insert-nabc-header]
    "---"
    ("Preview"
     ["Preview Line at Point" gregorio-preview-at-point]
     ["Preview Region" gregorio-preview-region :active (use-region-p)]
     ["Preview Buffer" gregorio-preview-buffer]
     ["Toggle Preview at Point" gregorio-preview-toggle]
     "---"
     ["Clear Preview at Point" gregorio-preview-clearout-at-point]
     ["Clear Previews in Region" gregorio-preview-clearout-region
      :active (use-region-p)]
     ["Clear All Previews" gregorio-preview-clearout-buffer]
     ["Abort Preview Job" gregorio-preview-abort])
    "---"
    ["Format Buffer" gregorio-format-buffer]
    ["Restart Language Server" gregorio-restart-language-server]))

;;; ---------------------------------------------------------------------------
;;; Mode definition
;;; ---------------------------------------------------------------------------

;;;###autoload
(define-derived-mode gregorio-mode prog-mode "Gregorio"
  "Major mode for editing GABC/NABC Gregorian chant notation.

\\{gregorio-mode-map}"
  :syntax-table gregorio-mode-syntax-table
  (setq-local comment-start "% ")
  (setq-local comment-end "")
  (setq-local comment-start-skip "%+[ \t]*")
  (setq-local syntax-propertize-function gregorio--syntax-propertize)
  (setq-local font-lock-defaults '(gregorio-font-lock-keywords nil nil))
  (setq-local font-lock-multiline nil)
  (setq-local imenu-create-index-function #'gregorio-imenu-create-index)
  (setq-local indent-tabs-mode nil)
  (setq-local tab-width 2)
  (add-hook 'after-change-functions #'gregorio--after-change nil t)
  (gregorio--maybe-start-lsp))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.gabc\\'" . gregorio-mode))

(provide 'gregorio-mode)

;;; gregorio-mode.el ends here
