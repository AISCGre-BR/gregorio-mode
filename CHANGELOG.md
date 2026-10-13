# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- `gregorio-preview`: inline score previews in the spirit of AUCTeX's
  preview-latex. Each body line is engraved with gregorio, LuaLaTeX
  (GregorioTeX) and pdftocairo, asynchronously, and the image replaces the
  source text. Previews can be toggled, are revealed when point enters them,
  are removed on edit and are only regenerated when the line changes. Bound
  to `C-c C-p` and listed in the Gregorio menu.
- Previews reuse the preamble and GregorioTeX setup of the LaTeX master
  document that includes the score, found automatically or set with
  `gregorio-preview-master`; `TEXINPUTS` covers its directory.
- `gregorio-preview-preamble` can be set per file;
  `gregorio-preview-add-local-preamble` writes it as a file-local variable.
- LaTeX errors are reported on the line that caused them (for example
  `Undefined control sequence \tikzmarknode`) without discarding the other
  previews; `gregorio-preview-explain-error` (`C-c C-p C-e`) explains them.
- `gregorio-preview-latex-passes` for packages that need two LuaLaTeX runs.

## [0.1.0] - 2026-10-13

### Added

- `gregorio-mode`: major mode for GABC/NABC files (`*.gabc`) with
  regex-based highlighting for headers, clefs, pitches, neume shapes,
  alterations, rhythmic signs, bars, custos, line breaks, spacing, attributes,
  macros, lyric markup tags, translations, comments and NABC notation, aware of
  the `nabc-lines` header.
- `gregorio-ts-mode`: tree-sitter variant using tree-sitter-gregorio v0.5.2
  (commit `c9034de8`), plus `gregorio-ts-install-grammar`.
- Editing commands ported from gregorio.nvim / vscode-gregorio:
  `gregorio-note-shift-up`, `gregorio-note-shift-down`,
  `gregorio-fill-parens`, `gregorio-convert-ligatures-to-tags` and
  `gregorio-convert-tags-to-ligatures`.
- gregorio-lsp integration through Eglot (default) or lsp-mode, with
  `gregorio-lsp-settings`, `gregorio-restart-language-server` and
  `gregorio-format-buffer` (falls back to `grefmt`).
- Templates, header skeletons, yasnippet snippets, imenu index, menu and
  `repeat-mode` support for note shifting.
- ERT test suite and Makefile.
