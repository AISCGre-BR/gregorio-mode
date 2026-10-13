;;; gregorio-ts-mode.el --- Tree-sitter mode for GABC/NABC Gregorian chant -*- lexical-binding: t; -*-

;; Copyright (C) 2026 AISCGre Brasil

;; Author: AISCGre Brasil
;; URL: https://github.com/AISCGre-BR/gregorio-mode
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: languages, music, tex
;; SPDX-License-Identifier: MIT

;; This file is not part of GNU Emacs.

;;; Commentary:

;; `gregorio-ts-mode' is a variant of `gregorio-mode' whose syntax
;; highlighting is driven by the tree-sitter-gregorio grammar
;; (https://github.com/AISCGre-BR/tree-sitter-gregorio).  All editing
;; commands, key bindings and the gregorio-lsp integration are inherited
;; from `gregorio-mode'.
;;
;; Install the grammar with \\[gregorio-ts-install-grammar], then either
;; call `gregorio-ts-mode' or make it the default for .gabc files:
;;
;;   (add-to-list 'major-mode-remap-alist '(gregorio-mode . gregorio-ts-mode))

;;; Code:

(require 'treesit)
(require 'gregorio-mode)

(defcustom gregorio-ts-grammar-recipe
  '("https://github.com/AISCGre-BR/tree-sitter-gregorio"
    "c9034de8f8c1c1605e9ccde29500f08e72ea51ff")
  "Source of the tree-sitter-gregorio grammar: (URL REVISION).
The revision is pinned to the release used by the sister extensions
\(zed-gregorio, vscode-gregorio and gregorio.nvim), v0.5.2."
  :type '(list (string :tag "URL") (string :tag "Revision"))
  :group 'gregorio)

;;;###autoload
(defun gregorio-ts-install-grammar ()
  "Download, compile and install the tree-sitter-gregorio grammar."
  (interactive)
  (let ((treesit-language-source-alist
         (cons (cons 'gregorio gregorio-ts-grammar-recipe)
               treesit-language-source-alist)))
    (treesit-install-language-grammar 'gregorio)))

(defconst gregorio-ts--nabc-letters
  '(augete altius altius_mediocriter bene celeriter celeriter_mediocriter
    coniunguntur celeriter_wide deprimatur equaliter equaliter_eq
    equaliter_dash equaliter_equ equaliter_wide fastigium fideliter frendor
    gutture humiliter humiliter_nectum humiliter_parum iusum
    iusum_mediocriter iusum_valde klenche levare levare_bene
    levare_celeriter leniter levare_mediocriter levare_parvum levare_tenere
    mediocriter mediocriter_md molliter non_tenere_negare_nectum_naturaliter
    non_levare non_tenere parvum paratim perfecte parvum_mediocriter pulcre
    sursum sursum_bene sursum_celeriter similiter simpliciter
    simpliciter_simpl simul sursum_mediocriter sursum_parum sursum_tenere
    statim tenere tenere_bene tenere_humiliter tenere_mediocriter
    tenere_wide valde volubiliter expectare
    ;; Tironian letters (Laon).
    deorsum devertit devexum prode_sub_eam quam_mox sub seorsum subjice
    saltim sonare supra saltate ut_supra
    significant_letter tironian_letter)
  "NABC significant and Tironian letter node types.")

(defconst gregorio-ts--nabc-neumes
  '(punctum tractulus gravis clivis pes porrectus torculus climacus
    scandicus porrectus_flexus scandicus_flexus torculus_resupinus trigonus
    pressus_maior pressus_minor virga_strata salicus pes_quassus pes_stratus
    nihil uncinus oriscus_clivis quilisma_3_loops quilisma_2_loops
    tractulus_episema tractulus_double_episema gravis_episema
    liquescens_stropha_cephalicus)
  "NABC neume node types.")

(defun gregorio-ts--style-rules ()
  "Return query patterns for styled syllable text."
  (let (patterns)
    (pcase-dolist (`(,style . ,face)
                   '((bold . gregorio-bold-face)
                     (italic . gregorio-italic-face)
                     (underline . gregorio-underline-face)
                     (small_caps . gregorio-small-caps-face)
                     (teletype . gregorio-teletype-face)
                     (colored . gregorio-colored-face)))
      (let ((node (intern (format "syllable_style_%s" style)))
            (open (intern (format "syllable_style_%s_open" style)))
            (close (intern (format "syllable_style_%s_close" style)))
            (cap (intern (format "@%s" face))))
        (push `(,node (syllable (syllable_text) ,cap)) patterns)
        (push `(syllable (,open) (syllable_text) ,cap) patterns)
        (push `(syllable (syllable_text) ,cap (,close)) patterns)))
    (nreverse patterns)))

(defvar gregorio-ts-font-lock-rules
  (treesit-font-lock-rules
   :language 'gregorio
   :feature 'comment
   '((comment) @font-lock-comment-face)

   :language 'gregorio
   :feature 'header
   '((header_name) @gregorio-header-name-face
     (header_numeric_mode name: _ @gregorio-header-name-face)
     (header_numeric_nabc_lines name: _ @gregorio-header-name-face)
     (header_numeric_staff_lines name: _ @gregorio-header-name-face)
     (header_tex_annotation name: _ @gregorio-header-name-face)
     (header_tex_mode_modifier name: _ @gregorio-header-name-face)
     (header_tex_mode_differentia name: _ @gregorio-header-name-face)
     (header_value_numeric) @gregorio-number-face
     (tex_code_header) @gregorio-verbatim-face
     (section_separator) @gregorio-separator-face)

   :language 'gregorio
   :feature 'clef
   '([(c_clef) (f_clef) (c_clef_flat)] @gregorio-clef-face)

   :language 'gregorio
   :feature 'pitch
   '([(pitch_lowercase) (pitch_uppercase)] @gregorio-pitch-face)

   :language 'gregorio
   :feature 'bar
   '([(virgula) (virgula_upper_ledger_line) (divisio_minimis)
      (divisio_minimis_upper_ledger_line) (divisio_minima)
      (divisio_minima_upper_ledger_line) (divisio_minor) (divisio_maior)
      (divisio_maior_dotted) (divisio_finalis) (dominican_bar)]
     @gregorio-bar-face)

   :language 'gregorio
   :feature 'custos
   '([(custos_auto_pitch) (custos_symbol) (force_custos) (disable_custos)
      (nocustos)]
     @gregorio-custos-face
     [(justified_line_break) (ragged_line_break)] @gregorio-line-break-face)

   :language 'gregorio
   :feature 'alteration
   '([(natural) (flat) (sharp) (natural_parenthesized) (flat_parenthesized)
      (sharp_parenthesized) (natural_soft) (flat_soft) (sharp_soft)
      (musica_ficta_natural) (musica_ficta_flat) (musica_ficta_sharp)]
     @gregorio-alteration-face)

   :language 'gregorio
   :feature 'shape
   '([(oriscus) (oriscus_scapus) (quilisma) (quilisma_quadratum) (quadratum)
      (virga) (virga_reversa) (bivirga) (trivirga) (stropha) (distropha)
      (tristropha) (linea) (cavum) (punctum_linea) (cavum_linea)
      (initio_debilis) (deminutus) (augmented) (diminished) (upwards)
      (downwards) (left_leaning) (right_leaning) (non_leaning)]
     @gregorio-shape-face)

   :language 'gregorio
   :feature 'rhythm
   '([(punctum_mora) (ictus) (always_below) (always_above) (episema)
      (below_note) (above_note) (disable_bridging) (small_left)
      (small_center) (small_right) (vertical_episema)
      (accent_above_staff) (accent_grave_above_staff) (circle_above_staff)
      (lower_semicircle_above_staff) (upper_semicircle_above_staff)]
     @gregorio-rhythm-face
     (brace) @gregorio-delimiter-face)

   :language 'gregorio
   :feature 'spacing
   '([(small_neume_separation) (medium_neume_separation) (large_space)
      (large_unbreakable_space) (half_space_same_neume)
      (small_space_same_neume) (zero_space) (scaled_large_neume_separation)
      (larger_space_right) (inter_element_space_right) (larger_space_left)
      (inter_element_space_left)]
     @gregorio-spacing-face)

   :language 'gregorio
   :feature 'attribute
   '([(shape) (stroke) (cs) (cn) (ob) (ub) (ocb) (ocba) (ll) (oll) (ull)
      (oslur) (uslur) (oh) (uh) (alt) (nv) (gv) (ev)]
     @gregorio-attribute-name-face
     (episema_position) @gregorio-attribute-value-face
     (tex_code) @gregorio-verbatim-face)

   :language 'gregorio
   :feature 'nabc
   `(,(vconcat (mapcar #'list gregorio-ts--nabc-neumes))
     @gregorio-nabc-neume-face
     [(subpunctis) (prepunctis)] @gregorio-shape-face
     [(mark_modification) (grouping_modification) (melodic_modification)
      (augmentive_liquescence) (diminutive_liquescence)]
     @gregorio-nabc-modifier-face
     [(variant_number) (repetition_count) (position_number)]
     @gregorio-number-face
     (pitch_descriptor) @gregorio-nabc-pitch-face
     ,(vconcat (mapcar #'list gregorio-ts--nabc-letters))
     @gregorio-nabc-letter-face)

   :language 'gregorio
   :feature 'lyric
   '((syllable_other_verbatim) @gregorio-verbatim-face
     (syllable_other_above_lines_text) @gregorio-attribute-value-face
     [(syllable_other_special_character) (syllable_escape_sequence)]
     @gregorio-special-char-face
     [(syllable_control_clear) (syllable_control_protrusion)
      (syllable_control_elision) (syllable_control_elision_open)
      (syllable_control_elision_close) (syllable_control_euouae)
      (syllable_control_euouae_open) (syllable_control_euouae_close)
      (syllable_control_no_line_break_open)
      (syllable_control_no_line_break_close)]
     @gregorio-tag-face
     (syllable_translation) @gregorio-translation-face
     [(syllable_centering) (lyric_tie)] @gregorio-centering-face
     ((syllable_text) @gregorio-asterisk-face
      (:match "\\`\\*+\\'" @gregorio-asterisk-face)))

   :language 'gregorio
   :feature 'style
   (gregorio-ts--style-rules)

   :language 'gregorio
   :feature 'error
   :override t
   '((ERROR) @font-lock-warning-face))
  "Tree-sitter font-lock settings for `gregorio-ts-mode'.")

;;;###autoload
(define-derived-mode gregorio-ts-mode gregorio-mode "Gregorio[ts]"
  "Major mode for GABC/NABC files, powered by tree-sitter-gregorio.

\\{gregorio-mode-map}"
  (when (treesit-ready-p 'gregorio)
    (treesit-parser-create 'gregorio)
    (setq-local treesit-font-lock-settings gregorio-ts-font-lock-rules)
    (setq-local treesit-font-lock-feature-list
                '((comment header)
                  (clef pitch bar)
                  (custos alteration shape rhythm spacing attribute nabc lyric
                          style)
                  (error)))
    (remove-hook 'after-change-functions #'gregorio--after-change t)
    (treesit-major-mode-setup)))

(provide 'gregorio-ts-mode)

;;; gregorio-ts-mode.el ends here
