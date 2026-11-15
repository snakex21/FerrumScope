# Kwarantanna referencji

**Katalog `do referencji/` oraz wszystko, co w nim jest, NIE wchodzi do repozytorium
FerrumScope, NIE jest dystrybuowane i NIE jest źródłem danych produktu.**

## Co tu jest

Kopie zastrzeżonych narzędzi: **CPU-Z** (CPUID / cpuz_x64.exe, cpuz_x32.exe) oraz
**GPU-Z** (TechPowerUp). Służą wyłącznie jako **oracle porównawczy** — do tego,
żeby sprawdzić, czy nasze dekodery czytają ze sprzętu to, co powinny, i czy nasza
baza pokrywa ten sam zakres.

## Czego tu nie robimy

- Nie kopiujemy **kodu** CPU-Z / GPU-Z.
- Nie kopiujemy ich **baz danych** (nazw SKU, tabel identyfikatorów, definicji
  sensorów) do `db/source/` ani do `ferrum-hwdb.bin`.
- Nie rozpakowujemy ich zasobów w celu pozyskania ich baz. Odczyt struktury pliku
  (sekcje, zasoby, importy) służy **rozumieniu architektury**, nie kopiowaniu danych.

## Co wolno

- Analiza statyczna: sekcje PE, importy, zasoby, sterowniki, format-stringi.
- Porównanie **wyników** (co narzędzie pokazuje) z naszym wynikiem.
- Wyciąganie **własnych** wniosków o architekturze podejścia.

## Dane wyprowadzone

`tools/refext/harvest_ref.py` zapisuje do `reference/dumps/*.json` ciągi znakowe
sklasyfikowane jako `cpu.marketing`, `gpu.chip`, `gpu.model`, `io.device_path` itd.
Pliki te są **wykluczone z repozytorium** (`.gitignore`) i oznaczone w treści
znacznikiem `QUARANTINE`.

Ich jedyne zastosowanie: wykrycie, jakich SKU brakuje w **naszej** bazie
(porównanie naszych wpisów z publicznym rejestrem), oraz testy naszych dekodera
na przykładach znanych identyfikatorów.

## Skąd realnie bierzemy dane

| Źródło | Status |
|---|---|
| PCI ID Repository (`pci-ids.ucw.cz`, BSD-like, atrybucja) | ✅ wdrożone |
| Dokumentacja producentów (AMD / Intel / NVIDIA / Apple) | planowane, ręcznie + `source_url` |
| Capture'y `.fcap` od użytkowników | planowane |
| `hwdata` z Linuksa (GPL-2.0+) | ❌ odrzucone — wymagałoby GPL dla całego projektu |
| Bazy CPU-Z / GPU-Z | ❌ kwarantanna |

Szczegóły: `docs/03-hwdb.md` §4.

## Powiązane

- Analiza: `docs/01-analiza-referencji.md`
- Narzędzia: `tools/refext/`
- Legalny importer: `tools/hwdb/pciids_import.py`
