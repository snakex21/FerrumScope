# FerrumScope — translation catalogs

This directory holds the user-interface translations of FerrumScope (GUI, CLI,
TXT/HTML reports). Every file is embedded into the program at build time
(`build.zig`, generated module `locales_embedded`), so the program works fully
offline and a broken catalog breaks the build/tests, not the user's program.

## Files

| file          | content                                                                 |
|---------------|-------------------------------------------------------------------------|
| `en.json`     | English — complete; the fallback for every other language               |
| `pl.json`     | Polish — the source language; contains **only plural forms**            |
| `xx.json`     | other languages (`bg cs da de el es et fi fr hr hu it lt lv nb nl pt-BR ro ru sk sl sr-Latn sv tr uk`) |

The list of languages lives in `src/i18n/i18n.zig` (`locales`, `native_names`)
and in `build.zig` (`i18n_locales`); a test checks that both agree.
Every listed file must exist; an untranslated language is just
`{"@locale": "xx"}`.

## Format

A flat JSON object (UTF-8, no BOM):

```json
{
  "@locale": "de",
  "Producent": "Hersteller",
  "{used} z {total} zajęte": "{used} von {total} belegt",
  "{n} dysków fizycznych": {
    "one": "{n} physisches Laufwerk",
    "other": "{n} physische Laufwerke"
  }
}
```

* **The key (message id) is the Polish source text**, exactly as written in the
  code (gettext model). Do not change keys — copy them from `en.json`.
* Keys starting with `@` are metadata (`@locale` = the file's language code).
* A missing entry falls back to English, then to the Polish source text.
* Key order does not matter; keep it the same as in `en.json` to make diffs easy.

### Named parameters

`{name}`, `{count}`, `{model}` … are replaced by the program. A translation must
contain **exactly the same set** of parameters as the key (order may change).
Never translate the text inside the braces. The test fails on a missing or
extra parameter.

### Plural forms (CLDR)

Entries whose value in `en.json` is an object are counted messages. `{n}` is
always the number. Provide the categories your language uses (CLDR rules for
integers, implemented in `i18n.pluralOf`) **plus `other`**:

| language                                     | categories                    |
|----------------------------------------------|-------------------------------|
| en de nl sv da nb fi et el it es bg hu tr    | `one`, `other`                |
| fr, pt-BR                                    | `one` (0 and 1), `other`      |
| pl                                           | `one`, `few`, `many` (+`other`) |
| ru, uk                                       | `one`, `few`, `many` (+`other`) |
| cs, sk                                       | `one`, `few`, `other`         |
| hr, sr-Latn                                  | `one`, `few`, `other`         |
| sl                                           | `one`, `two`, `few`, `other`  |
| lt                                           | `one`, `few`, `other`         |
| lv                                           | `zero`, `one`, `other`        |
| ro                                           | `one`, `few`, `other`         |

### Context (homonyms)

A key may start with a context and the control character U+0004, e.g.
`"pamięć\u0004Gniazdo"` = the word "Gniazdo" meaning a *memory slot* (the plain
key `"Gniazdo"` means a *CPU socket*). Translate only the text; the context is
a hint for you.

### Instance-section templates — must start with fixed text

The GUI finds per-device sections by the fixed beginning and end of these
templates, so their translations **must start with fixed text and keep the
parameter(s) as one block**:

| key                       | example (en)              |
|---------------------------|---------------------------|
| `GPU: {name}`             | `GPU: {name}`             |
| `Czujniki GPU: {name}`    | `GPU sensors: {name}`     |
| `Gniazdo {slot}`          | `Slot {slot}`             |
| `Dysk {index}: {model}`   | `Drive {index}: {model}`  |

Wrong: `{name} GPU` (starts with a parameter). The fixed prefixes of the four
templates must also differ from each other and from the other section titles
on the same page.

### What is not translated

Technical values never go through the catalog and must not be translated
inside keys either: instruction names (AVX2, SHA…), x86-64 levels, units
(MHz, GB, °C, W, RPM, %), PCI IDs, SMBIOS specification references
(`SMBIOS typ 17`, `type 2, offset 05h`), CPUID leaf names, API names (DXGI,
SetupAPI, `IOCTL_…`, NVAPI, ADL), vendor and product names. If such a token
appears inside a sentence, keep it unchanged in the translation. The JSON
export keeps fixed English keys; only its values follow the language.

## Choosing the language

Order: `--lang=<code>` (CLI and GUI) → `language` in `data\settings.ini` →
Windows UI language → English. CLI: `ferrumscope lang` shows the current
language, `ferrumscope lang <code>` saves it (`auto` = follow Windows). GUI:
the language picker on the "About" tab saves the setting and restarts the window.

## Checking a catalog

```
tools\zig\zig-x86_64-windows-0.15.2\zig.exe build test --summary all
```

The tests in `src/i18n/catalog_test.zig` scan `src/**/*.zig` for message ids
(string literals passed to `t(`, `tf(`, `tp(`, `N(` and the tables in
`src/gui/forms.zig`) and check every catalog: no keys unknown to the code,
identical `{parameters}`, required plural categories. `en.json` must contain
every id. A language listed in `pending_locales` (same file) may still be
incomplete — when your catalog is complete, remove its code from that list so
the test keeps it complete.

To list the ids missing from a catalog, run the test: it prints
`[xx] brak tłumaczenia: "…"` for up to 40 missing entries per language once the
code is removed from `pending_locales`.
