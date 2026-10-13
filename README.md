# gregorio-mode

> [!NOTE]
> **AI-Assisted Development**
>
> This project is developed, fully or in part, with LLM/generative AI assistance.
> All LLM-proposed changes go through human review and local testing before being committed.
>
> If you object to software built with generative AI assistance, we respect your opinion
> and regret we cannot meet your expectations. In that case, we kindly recommend exploring
> alternative solutions. If you know of any, feel free to open an issue — we'll be happy
> to include them in our documentation.

Emacs major mode for **GABC/NABC** (Gregorian chant notation) files, as used by
[Gregorio](https://gregorio-project.github.io).

This is the Emacs counterpart of [gregorio.nvim](https://github.com/AISCGre-BR/gregorio.nvim),
[vscode-gregorio](https://github.com/AISCGre-BR/vscode-gregorio) and
[zed-gregorio](https://github.com/AISCGre-BR/zed-gregorio), sharing the same
ecosystem: the [tree-sitter-gregorio](https://github.com/AISCGre-BR/tree-sitter-gregorio)
grammar and the [gregorio-lsp](https://github.com/AISCGre-BR/gregorio-lsp) language server.

## Features

- **Syntax highlighting** (`gregorio-mode`) — dependency-free, regex-based
  highlighting for headers, clefs, pitches, neume shapes, alterations,
  rhythmic signs, bars, custos, line breaks, spacing, note attributes, macros,
  lyric markup tags (`<b>`, `<i>`, `<c>`, `<sc>`, `<sp>`, `<v>`, …), translations,
  comments and **NABC** (St. Gall / Laon) notation. GABC and NABC segments in a
  note group are told apart according to the **`nabc-lines`** header, just like
  the semantic layer of vscode-gregorio.
- **Tree-sitter highlighting** (`gregorio-ts-mode`, optional) — highlighting
  driven by the tree-sitter-gregorio grammar (pinned to v0.5.2, commit
  `c9034de8`, the same revision used by the sister extensions).
- **Language server** — diagnostics, hover, completion, document symbols, code
  actions and formatting via gregorio-lsp, started automatically with Eglot
  (or lsp-mode).
- **Formatting** — `gregorio-format-buffer` uses the language server, or the
  `grefmt` command-line formatter when no server is running.
- **Editing commands**
  - Shift notes up / down (diatonic transposition, cyclic wrap
    `… n p a b …`, `nabc-lines`-aware, numeric prefix argument for several steps).
  - Fill empty note groups `()` with the last pitch of the preceding group.
  - Convert ligatures `æ`/`ǽ`/`œ` ↔ `<sp>ae</sp>`/`<sp>'ae</sp>`/`<sp>oe</sp>`.
- **Templates, skeletons and snippets** — starter templates, header skeletons
  and a [yasnippet](https://github.com/joaotavora/yasnippet) snippet collection
  ported from gregorio.nvim and vscode-gregorio.
- **Score preview** — inline previews of the engraved score, in the spirit of
  AUCTeX's preview-latex: each line of the chant body is replaced by its
  rendered image.
- **Imenu** — headers and the start of the body are listed in `imenu`.
- **Comments** — `%` comments work with `comment-dwim` (`M-;`).

## Requirements

- Emacs 29.1 or later (tree-sitter support compiled in for `gregorio-ts-mode`).
- Optional: `gregorio-lsp` (and `grefmt`) on your `PATH` for language-server
  features and formatting:

  ```sh
  cargo install --git https://github.com/AISCGre-BR/gregorio-lsp \
    --tag v0.11.0 gregorio-server --bin gregorio-lsp
  cargo install --git https://github.com/AISCGre-BR/gregorio-lsp \
    --tag v0.11.0 gregorio-cli --bin grefmt   # optional formatter fallback
  ```

  Make sure `~/.cargo/bin` is on your `PATH` (or `exec-path`), or set
  `gregorio-lsp-command` to the absolute path of the binary.
- Optional, for score previews: `gregorio`, LuaLaTeX with GregorioTeX (TeX
  Live) and `pdftocairo` (poppler).

## Installation

### `package-vc` (Emacs 29+)

```elisp
(package-vc-install "https://github.com/AISCGre-BR/gregorio-mode")
```

### `use-package` (Emacs 30+)

```elisp
(use-package gregorio-mode
  :vc (:url "https://github.com/AISCGre-BR/gregorio-mode" :rev :newest)
  :mode "\\.gabc\\'")
```

### Manual

```elisp
(add-to-list 'load-path "/path/to/gregorio-mode")
(require 'gregorio-mode)
(require 'gregorio-ts-mode) ; optional
```

`.gabc` files open in `gregorio-mode` automatically.

## Tree-sitter mode

Install the grammar once, then make `gregorio-ts-mode` the default:

```elisp
M-x gregorio-ts-install-grammar

(add-to-list 'major-mode-remap-alist '(gregorio-mode . gregorio-ts-mode))
```

`gregorio-ts-mode` derives from `gregorio-mode`, so all commands, key bindings
and the language-server integration are the same. Highlighting is organized in
the usual `treesit-font-lock-level` levels; level 4 additionally highlights
parse errors.

> **Note**: the pinned grammar does not yet resolve the GABC/NABC alternation
> for `nabc-lines` values greater than 1; the regex-based `gregorio-mode` does.

## Score preview

Inline previews work like AUCTeX's preview-latex. `C-c C-p C-b` engraves every
line of the chant body and shows the rendered image in place of the source text.
Each line is typeset on its own: the buffer header is repeated (only the
first line keeps the initial and the annotation), and the clef in effect is
prepended when the line does not start with one.

- `RET` or a click on an image shows the source again; `C-c C-p C-p` switches
  back to the image.
- With `gregorio-preview-auto-reveal` (the default), the source is revealed
  when point enters a preview and hidden again when point leaves it.
- Editing a line removes its preview. Previewing again only regenerates lines
  that changed.
- Lines that fail to compile are marked with ⚠; hover over the mark for the
  message. A LaTeX error only affects the line that caused it.
  `C-c C-p C-e` (or a click on ⚠) explains the error, with shortcuts to the
  log, the master document and the preamble settings.
- Previews are generated asynchronously; `C-c C-p C-k` aborts a running job.

| Key | Command |
|---|---|
| `C-c C-p C-p` | `gregorio-preview-at-point` — preview the line at point, or toggle its preview |
| `C-c C-p C-r` | `gregorio-preview-region` — preview the lines in the region |
| `C-c C-p C-b` | `gregorio-preview-buffer` — preview the whole body |
| `C-c C-p C-c C-p` | `gregorio-preview-clearout-at-point` |
| `C-c C-p C-c C-r` | `gregorio-preview-clearout-region` |
| `C-c C-p C-c C-b` | `gregorio-preview-clearout-buffer` |
| `C-c C-p C-e` | `gregorio-preview-explain-error` |
| `C-c C-p C-k` | `gregorio-preview-abort` |
| — | `gregorio-preview-add-local-preamble` |

### LaTeX packages used by the score

GABC files may contain arbitrary LaTeX, such as `<v>\tikzmarknode{a}{…}</v>`,
which needs packages that a bare preview document does not load. The preview
document gets them from three places:

1. **The master document.** By default, gregorio-mode looks for a `.tex` file
   that includes the score with `\gregorioscore{…}` (or `\includescore`). The
   search starts in the directory of the GABC file and goes up
   `gregorio-preview-master-search-depth` levels (3), never above the project
   root. Its preamble (everything before `\begin{document}`) is reused, as are
   the GregorioTeX setup commands (`\gresetX…`, `\grechangeX…`) that come
   before the score in the document body. The directories of the master
   document and of the GABC file are added to `TEXINPUTS`, so that relative
   `\input` and local packages work. Set `gregorio-preview-master` to a file
   name to choose the master document, or to `none` to disable this.
2. **`gregorio-preview-preamble`**, globally or per file.
   `M-x gregorio-preview-add-local-preamble` writes it as a file-local
   variable:

   ```gabc
   % Local Variables:
   % gregorio-preview-preamble: "\\usepackage{tikz}\\usetikzlibrary{tikzmark}"
   % End:
   ```

   Both variables also work in `.dir-locals.el`.
3. **`gregorio-preview-latex-passes`**: set it to `2` for packages that only
   place their elements on a second LuaLaTeX run, such as tikzmark with
   `remember picture`.

> **Security**: previews run LuaLaTeX on the LaTeX code of the score and of
> the master document, and LuaLaTeX can run Lua code. Only preview files you
> trust. Emacs asks before applying file-local values of
> `gregorio-preview-preamble` and `gregorio-preview-master`.

**Requirements**: `gregorio`, LuaLaTeX with GregorioTeX and `preview.sty` (all
included in TeX Live), and `pdftocairo` (poppler). The versions of `gregorio`
and GregorioTeX must match.

```elisp
;; Size of the previews relative to the default font.
(setq gregorio-preview-scale 1.2)

;; Line width: nil follows the window width, or a TeX dimension.
(setq gregorio-preview-text-width "15cm")

;; Extra LaTeX preamble code (packages, fonts, GregorioTeX settings, ...).
(setq gregorio-preview-preamble "\\usepackage{tikz}\\usetikzlibrary{tikzmark}")

;; Master document whose preamble is reused (nil: find it; none: disable).
(setq gregorio-preview-master nil)

;; Number of LuaLaTeX runs.
(setq gregorio-preview-latex-passes 1)

;; Render scores in black instead of the theme's foreground color.
(setq gregorio-preview-use-face-color nil)

;; Use SVG images instead of PNG.
(setq gregorio-preview-image-type 'svg)
```

## Commands and key bindings

| Key | Command | Description |
|---|---|---|
| `C-c C-u` | `gregorio-note-shift-up` | Shift notes up (prefix argument: number of steps) |
| `C-c C-d` | `gregorio-note-shift-down` | Shift notes down (prefix argument: number of steps) |
| `C-c C-f` | `gregorio-fill-parens` | Fill empty note groups with the last preceding pitch |
| `C-c C-l` | `gregorio-convert-ligatures-to-tags` | `æ`, `ǽ`, `œ` → `<sp>` tags |
| `C-c C-t` | `gregorio-convert-tags-to-ligatures` | `<sp>` tags → `æ`, `ǽ`, `œ` |
| `C-c C-r` | `gregorio-format-buffer` | Format with gregorio-lsp or `grefmt` |
| `C-c C-i` | `gregorio-insert-template` | Insert a starter template |
| `C-c C-p …` | preview commands | See [Score preview](#score-preview) |
| — | `gregorio-insert-header` | Header skeleton |
| — | `gregorio-insert-nabc-header` | Header skeleton with `nabc-lines` |
| — | `gregorio-restart-language-server` | Restart gregorio-lsp |
| — | `gregorio-ts-install-grammar` | Install the tree-sitter grammar |

With `repeat-mode` enabled, after `C-c C-u` or `C-c C-d` you can keep pressing
`u` / `d` to shift again. The region stays active between shifts.

All commands are also available from the **Gregorio** menu.

### Command behavior

- **Scope** — editing commands act on the active region or, without one, on the
  whole chant body (everything after `%%`). The header is never modified.
- **Note shifting** only changes pitch letters inside note groups `(...)`.
  Lyrics, comments, clef groups (`(c4)`, `(cb3)`, `(f3)`), bracketed attributes
  (`[nv:…]`, `[oh:…]`, …) and NABC segments are preserved; accidentals and custos
  keep their modifier (`gx` → `hx`, `f+` → `g+`); fusions `@[…]` are shifted.
- **`nabc-lines`** — in a group `(s0|s1|…|sN)`, segment `i` is GABC when
  `i mod (nabc-lines + 1) = 0`. Example with `nabc-lines: 2;`: in
  `(fg|vi|pe|hi|ta|cl)` only `fg` and `hi` are shifted. Without the header,
  only the first segment is GABC.
- **Fill parens** fills each empty group (`()` or `( )`) with the last pitch of
  the nearest preceding non-empty group, tracking state across the whole body:
  `(fgh) () () (ij) ()` → `(fgh) (h) (h) (ij) (j)`. Clef groups do not update
  the tracked pitch. With a region, only groups inside it are filled.

## Configuration

```elisp
;; LSP client used to start gregorio-lsp automatically: eglot, lsp-mode or nil.
(setq gregorio-lsp-client 'eglot)

;; Server command.
(setq gregorio-lsp-command '("gregorio-lsp"))

;; Settings sent through workspace/didChangeConfiguration (see gregorio-lsp's
;; CONFIG.md). nil keeps the server defaults.
(setq gregorio-lsp-settings
      '(:linting (:enabled t :severity "warning" :ignoreRules [])
        :formatting (:maxLineWidth 80
                     :breakAfterClef :json-false
                     :breakAfterBar :json-false)))

;; grefmt fallback used by `gregorio-format-buffer' without a server.
(setq gregorio-grefmt-args '("--width" "80"))

;; Format on save.
(add-hook 'gregorio-mode-hook
          (lambda () (add-hook 'before-save-hook #'gregorio-format-buffer nil t)))
```

All faces (`gregorio-pitch-face`, `gregorio-clef-face`, `gregorio-nabc-neume-face`,
…) inherit from standard `font-lock` faces and can be customized with
`M-x customize-group RET gregorio-faces`. Text inside `<c>…</c>` is shown in
red, as rubrics are printed by Gregorio.

## Snippets and templates

- `templates/` — `basic`, `nabc` and `advanced` starter templates
  (`C-c C-i`).
- `snippets/gregorio-mode/` — yasnippet snippets, registered automatically when
  yasnippet is loaded: `gabcheader`, `nabcheader`, response markings (`a/.`,
  `r/.`, `v/.` and colored variants), markup tags (`bold`, `italic`, `color`,
  `smallcaps`, `underline`, `teletype`, `special`, `verbatim`, `alt`, …), special
  characters and verbatim brackets, `trans`, `notes`, `clef`, `divisio`,
  `virgula`, `finalis` and common neume helpers.

## Development

```sh
make compile   # byte-compile with warnings as errors
make checkdoc  # documentation style checks
make test      # ERT test suite
make           # all of the above
```

## License

MIT — Copyright (c) 2026 AISCGre Brasil. See [LICENSE](LICENSE).
