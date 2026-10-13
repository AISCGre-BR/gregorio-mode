# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

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
