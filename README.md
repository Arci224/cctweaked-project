# SleepMon

Monitorovací aplikace pro CC:Tweaked (Advanced Computer) — hodiny se
signalizací spánku, tok a zásoba energie, postup quarry, stav zařízení.
Součástí je automatická aktualizace z GitHubu a sběr logů z ostatních
počítačů.

Testováno na NeoForge 1.21.1, modpack FTB Evolution.

## Soubory

| Soubor | Kde běží | Co dělá |
|---|---|---|
| `boot.lua` | všude (jako `startup.lua`) | pozná roli, aktualizuje, spustí aplikaci |
| `updater.lua` | všude | stahování z GitHubu, distribuce po rednetu, log |
| `sleepmon.lua` | hlavní PC | vlastní aplikace s monitorem |
| `sender.lua` | vzdálené PC | čte senzory a vysílá je po rednetu |
| `scan.lua` | kdekoli | diagnostika připojených periferií |
| `nbt.lua` | u quarry | výpis NBT přes Block Reader |
| `manifest.json` | GitHub | seznam souborů a číslo verze |
| `install.lua` | GitHub | první instalace |

## Topologie

```
                    GitHub
                       |  HTTP
                       v
   [PC1 hlavní] <---------------> [PC2 základna]   detektor + energy cube
    monitor 5x3        rednet
    speaker            (ender)  <-> [PC3 quarry]   block reader
```

Vzdálené počítače HTTP nepotřebují — novou verzi si vyžádají od PC1.
Počítač v jiné dimenzi **musí mít Ender Modem**, obyčejný wireless
hranici dimenzí nepřekročí.

## Založení repozitáře

```bash
git init
git add .
git commit -m "SleepMon"
git branch -M main
git remote add origin https://github.com/UZIVATEL/sleepmon.git
git push -u origin main
```

Repozitář musí být **veřejný**, jinak se k `raw.githubusercontent.com`
počítač nedostane (nemá jak poslat token).

Pak v `updater.lua` a `install.lua` přepiš `UZIVATEL` a `sleepmon` na
své hodnoty a pushni znovu.

## Instalace na počítač

Pokud má počítač HTTP:

```
wget run https://raw.githubusercontent.com/UZIVATEL/sleepmon/main/install.lua
```

Když HTTP na serveru není povolené, zkopíruj ručně `boot.lua` (jako
`startup.lua`) a `updater.lua`. Zbytek si počítač stáhne od PC1.

Roli si `boot.lua` určí sám: **s monitorem = hlavní, bez monitoru =
vzdálený**. Vynutit se dá souborem `/.sleepmon_role` s obsahem `main`
nebo `remote`.

## Vydání nové verze

1. Uprav soubory
2. **Zvyš `version` v `manifest.json`** — bez toho se nic nestáhne
3. `git push`
4. Na PC1 stiskni *Aktualizovat* v záložce Log (nebo počkej na reboot)
5. Vzdálené počítače si novou verzi vezmou při svém dalším startu

## Pojistky proti rozbití

Špatný update umí zabít počítač, ke kterému se těžko dostáváš. Proto:

- `.lua` soubor se zapíše, **jen když projde `load()`** — syntaktická
  chyba se nikam nedostane
- předchozí verze zůstává jako `<soubor>.bak`
- když aplikace po startu spadne, `boot.lua` obnoví zálohu a rebootuje
- obnova proběhne **jen jednou**; pak se počítač zastaví s výpisem
  chyby, aby se netočil ve smyčce

Co to **neodchytí**: běhovou chybu, která se projeví až po čase, a
logickou chybu. Kód projde překladem a spustí se.

## Log

Vzdálené počítače hlásí na PC1 start, výpadky periferií a pády
aplikace. Zobrazuje se v záložce **Log**; položka v menu zčervená, když
přijde chyba. Delší výpis diagnostiky dělá `scan` přímo na daném
počítači.

## Poznámky k jednotkám

Mekanism vrací energii přes vlastní metody, ne přes CC generic
peripheral. Absolutní hodnoty jsou proto v joulech, ne ve FE — aplikace
to poznamenává jednotkou `E` místo `FE`. Procenta a odhady výdrže jsou
na jednotce nezávislé.

## Známá omezení

- Bouřka ve vanille dovolí spát i přes den; CC nemá API na počasí,
  takže to hodiny nepoznají.
- Font CC:Tweaked neumí českou diakritiku, texty jsou bez háčků.
- Odhad dotěžení quarry je lineární extrapolace. Horní vrstvy jsou
  plné vzduchu a jdou rychleji než kámen dole, takže první polovina
  odhadu je optimistická.
- Když quarry nemá nastavené `digMinY`, spodní hranice se odhaduje
  (výchozí −64) a přímo škáluje celkový objem.
