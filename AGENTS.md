# AGENTS.md — AI Code Generation Guide for gregorio-mode

This document is the primary reference for AI agents contributing to this
repository. Read it before making changes.

> **Language policy**: All content in this repository **must be in English** —
> source identifiers, comments, docstrings, documentation, commit messages, and
> any other human-readable text.

## 1. Project Overview

`gregorio-mode` is an Emacs package for **GABC/NABC** Gregorian chant notation.
It is the Emacs counterpart of `gregorio.nvim`, `vscode-gregorio` and
`zed-gregorio`, and integrates the same ecosystem:

- **[tree-sitter-gregorio](https://github.com/AISCGre-BR/tree-sitter-gregorio)** —
  grammar used by `gregorio-ts-mode` (pinned to v0.5.2, commit `c9034de8`).
- **[gregorio-lsp](https://github.com/AISCGre-BR/gregorio-lsp)** — language
  server (diagnostics, hover, completion, symbols, code actions, formatting)
  and the `grefmt` formatter.

## 2. Repository Structure

```
gregorio-mode.el          ← major mode: faces, regex font-lock, syntax table,
                            editing commands, templates, LSP wiring, keymap
gregorio-ts-mode.el       ← tree-sitter variant (derives from gregorio-mode)
gregorio-preview.el       ← inline score previews (preview-latex style)
test/*-test.el            ← ERT tests
templates/*.gabc          ← starter templates (gregorio-insert-template)
snippets/gregorio-mode/   ← yasnippet snippets
examples/*.gabc           ← sample files for manual highlighting checks
Makefile                  ← compile / checkdoc / test
```

## 3. Development Workflow

```sh
make compile   # byte-compile; warnings are errors
make checkdoc  # docstring conventions
make test      # ERT
```

Every change must keep all three green. Test `gregorio-ts-mode` manually with
a compiled grammar (`M-x gregorio-ts-install-grammar`, or build `src/parser.c`
of tree-sitter-gregorio into `libtree-sitter-gregorio.so` and add its
directory to `treesit-extra-load-path`).

## 4. Architecture Notes

### 4.1 Highlighting

- `gregorio--context` classifies a position as `header`, `separator`,
  `comment`, `lyric`, `gabc`, `nabc` or `attribute` by scanning the current
  line. Every font-lock rule is built with `gregorio--matcher`, which restricts
  a regexp to a set of contexts. Keep matchers free of zero-length matches and
  wrap any code that may search inside `save-match-data`.
- Rule order matters: a rule does not override text fontified by an earlier
  rule (unless it uses `t`, `keep`, `prepend` or `append`), so put specific
  rules before generic ones.
- Changing `%%` or `nabc-lines` triggers `font-lock-flush` via
  `gregorio--after-change`.
- `gregorio-ts-mode` uses the same `gregorio-*-face` faces. When updating the
  grammar revision, check node names against its `node-types.json`: an unknown
  node makes the whole query fail.

### 4.2 Editing commands

Preserve the semantics shared with the sister projects and gregorio-core:

- Commands act on the region, or on the whole body after `%%`; never on the
  header. Without a `%%` separator they signal a `user-error`.
- In a group `(s0|s1|…|sN)`, segment `i` is GABC iff
  `i mod (nabc-lines + 1) = 0`; without `nabc-lines`, only `s0` is GABC.
- Pitch cycle: `a b c d e f g h i j k l m n p` (no `o`), case preserved.
- Clef groups, comments, `$`-escapes, `<v>…</v>` lyrics and `[…]` attributes
  are skipped; fusions `@[…]` are not.

### 4.3 Language server

`gregorio-lsp-command` is registered in `eglot-server-programs` (language id
`gabc`) and as an lsp-mode client. `gregorio-lsp-settings` is pushed with
`workspace/didChangeConfiguration` after connection. Do not add network
downloads of the server binary.

### 4.4 Score preview

`gregorio-preview.el` is loaded on demand through the autoloads and the
`C-c C-p` keymap in `gregorio-mode.el`.

- `gregorio-preview--chunks` turns each non-blank, non-comment body line into a
  standalone GABC document. The document repeats the header (`annotation` is
  dropped after the first line) and prepends the clef in effect.
- A job runs `gregorio` on each chunk, then LuaLaTeX
  (`gregorio-preview-latex-passes` runs, one `preview` environment per chunk,
  `\gregorioscore[n]{chunk-N.gtex}`), then `pdftocairo`. Each step is an
  asynchronous process chained through sentinels.
- preview.sty is loaded with the `auctex` option, so the log marks where each
  snippet starts and ends. `gregorio-preview--parse-log` assigns each error to
  its snippet, and snippet N is page N of the PDF. Do not add
  `-halt-on-error`: one bad line must not discard the others.
- The preamble comes from the master document and `gregorio-preview-preamble`.
  `gregorio-preview--find-master` finds the file that includes the score
  (`gregorio-preview--score-reference` accepts any macro whose argument names
  the GABC file, except those in `gregorio-preview--non-score-commands`), then
  `gregorio-preview--tex-root` follows `%! TeX root`, `subfiles` and
  `TeX-master` up to the root. The fallback is the project's main document.
  The search recurses only inside a project, never from an arbitrary
  ancestor. The result is cached per buffer (`gregorio-preview--master`).
  `gregorio-preview--master-preamble` returns the root preamble plus the setup
  commands of the root body and of the including file. LuaLaTeX runs in the
  root's directory with `-output-directory` set to the job directory.
  `\PassOptionsToPackage` comes before the master's `\documentclass`, and the
  line width is set after `\begin{document}`, so that geometry and the
  master's own `preview` loading do not get in the way.
- Overlay states: `busy`, `shown`, `revealed`, `error`. Images are stored as
  data on the overlay, so the temporary directory is deleted when the job
  ends. The cache key (`gregorio-preview--key`) covers the chunk text and the
  rendering settings, including the master preamble.
- The integration tests are skipped when the toolchain is not installed.

## 5. Conventions

- Emacs 29.1 is the minimum version; guard newer APIs.
- Public symbols use the `gregorio-` prefix, private ones `gregorio--`.
- Update `README.md` and `CHANGELOG.md` when behavior changes.
- **Conventional Commits** (`feat:`, `fix:`, `docs:`, `chore:`, `refactor:`,
  `test:`).
