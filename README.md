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
4. Na PC1 v záložce **Zarizeni** stiskni **Stahnout** — stáhne jen na PC1
5. **Restart** PC1 a ověř, že nová verze běží
6. Teprve pak **Rozeslat** ostatním
7. Počkej, až budou u všech počítačů stejná čísla verzí

Stažení a rozeslání jsou záměrně dvě akce. Kdyby to bylo spojené,
rozbitá verze se dostane na stroj v jiné dimenzi dřív, než si jí
všimneš.

Ovládání je v záložce Zarizeni:

| Prvek | Co dělá |
|---|---|
| `Stahnout` | PC1 stáhne novou verzi z GitHubu, nikam ji neposílá |
| `Rozeslat` | pošle výzvu všem, kdo nemají verzi PC1 (s opakováním) |
| `Restart` | restartuje PC1 |
| `D` u zdroje | detail toho stroje |
| `>` u zdroje | pošle výzvu k aktualizaci jen tomu počítači |
| `R` u zdroje | restartuje jen ten počítač |

`>` a `R` se posílají **adresně**, nikdy broadcastem — `R` by jinak
restartoval všechno naráz. Obě tlačítka jsou bez potvrzení, tak pozor
na překlepnutí prstem; restart je ale zotavitelný, počítač naběhne sám.

Pořadí není libovolné: vzdálené počítače si soubory tahají **z PC1**,
takže musí zůstat naběhnuté, dokud se neaktualizují. Proto se PC1
nerestartuje sám.

Tlačítko **Rozeslat** pošle výzvu znovu bez stahování — na počítač,
který byl zrovna offline nebo v nenačteném chunku.

### Čtení logu

Každý řádek má směr komunikace:

| Značka | Význam |
|---|---|
| `.` | PC1 sám (stahování z GitHubu, zápis souborů) |
| `>` | PC1 → protějšek (odchozí) |
| `<` | protějšek → PC1 (příchozí) |

Jméno protějšku se píše jen když se změní — při výměně zpráv se střídají,
takže je vidět celý dialog; u série řádků od jednoho počítače zbude víc
místa na text.

Rolování je na řádku nad tlačítky: `^` a `v` po stránkách, `konec` skočí
na nejnovější. Vpravo je pozice, třeba `112-125/300`. Když roluješ
historii, nové záznamy ti výpis nepodsunou — číslo zežloutne a zůstaneš,
kde jsi.

### Co se loguje

Celý průběh aktualizace, po krocích. Šedě jsou `debug` řádky, bíle
`info`, zeleně `ok`, červeně chyby.

```
03:11 PC1:        GitHub hlasi v7, 6 souboru
03:11 PC1:        stahuji boot.lua (1/6)
03:11 PC1:        boot.lua: 4812 B
03:11 PC1:        stazeno vse, zapisuji
03:11 PC1:        zapsano 6 souboru, v7
03:11 PC1:        vyzva -> v7
03:11 Nether:     vyzva v7, stahuji
03:11 Nether:     zadam PC1 o manifest, mam v6
03:11 PC1:        PC7 zada manifest -> v7, 6 souboru
03:11 Nether:     PC1 hlasi v7, 6 souboru
03:11 Nether:     zadam sender.lua (4/6)
03:11 PC1:        PC7 <- sender.lua (12148 B, 3 casti)
03:11 Nether:     sender.lua prijato, 12148 B
03:11 Nether:     prijato vse, instaluji 6 souboru
03:11 Nether:     zapsan sender.lua
03:11 Nether:     instalace hotova, v7
03:11 Nether:     v7, restart
03:12 Nether:     boot: rezim remote, v7
03:12 Nether:     spoustim sender.lua
03:12 Nether:     sender v7 bezi +det +qry
03:12 Nether:     v6 -> v7
```

Vidíš tedy obě strany přenosu — kdo co žádal, kolik bajtů přišlo,
který soubor se zapsal a čím to skončilo. Když se instalace zastaví na
syntaktické chybě, poslední řádek je červený a řekne u kterého souboru.

Vzdálený počítač vystupuje pod svým aliasem, ne pod názvem počítače.

Buffer drží 300 řádků.

### Komu se výzva posílá

`rednet.broadcast` nemá adresáta ani potvrzení o doručení. PC1 si proto
vede vlastní seznam: každý počítač, který se kdy ozval, je v registru
očekávaných zařízení pod svým ID.

Při *Rozeslat* se výzva pošle **adresně každému známému ID**, které
ještě nemá cílovou verzi, plus broadcastem navíc kvůli počítačům,
které PC1 nikdy neviděl. Do logu se vypíše, komu přesně:

```
vyzva v7 -> Nether main(7), Zakladna(2)
```

Pak se čeká 45 s. Kdo se neozve, dostane výzvu znovu, celkem třikrát.
Nakonec se vypíše červeně, kdo se neozval vůbec:

```
neodpovedelo: Zakladna(2)
stahnou si ji pri svem dalsim startu
```

**Retry nespraví vypnutý počítač.** Když je chunk nenačtený, žádný
program tam neběží a doručit se nedá nic. Skutečná záchrana je, že si
`boot.lua` vyžádá aktuální verzi sám při startu — takže se to srovná,
až se ten chunk zase načte.

### Zpětná vazba

- V záhlaví záložky Log je `v5  2/3 hotovo` — kolik vzdálených počítačů
  už hlásí stejnou verzi jako PC1. Zezelená, až budou všechny.
- Když počítač verzi změní, objeví se v logu řádek `Nether main:
  v4 -> v5`.
- V záložce Zarizeni je verze u každého počítače. **`v?` znamená, že
  verzi vůbec nehlásí** — běží na kódu starším než v5.

### První nasazení push updatu

Zpracování výzvy je novinka verze 5. Počítač se starším kódem ji
ignoruje, protože v sobě nemá řádek, který by ji poslouchal — push
mechanismus se nedá zavést pushem.

Napoprvé tedy jdi na každý vzdálený počítač a dej `reboot`. Při startu
si soubory vyžádá sám (to umí i starý `boot.lua`). Od té chvíle už
stačí *Rozeslat* z PC1.

Každý vzdálený počítač si počká `ID % 12` sekund, než si o soubory
řekne. Deset strojů se tak neslije do jedné dávky.

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

## Alias stanoviště

Na vzdáleném počítači stiskni **A** a napiš jméno (max 16 znaků).
Uloží se do `/.sleepmon_alias`, posílá se s každou zprávou a PC1 ho
použije místo `QRY3` / `BAT3` u všeho, co ten počítač hlásí. Prázdný
vstup alias zruší. Změna se na PC1 projeví hned, restart není potřeba.

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
- Odhad dotěžení quarry je lineární extrapolace z posledních 5 minut.
  Sedí, dokud je tempo konstantní — vrstvy s velkým podílem vzduchu
  (jeskyně, povrch) proletí rychleji a odhad se pak prodlouží.
- Když quarry nemá nastavené `digMinY`, spodní hranice se odhaduje a
  přímo škáluje celkový objem. **Overworld má dno v −64, Nether a End
  v 0** — nastavuje se pro každý stroj zvlášť na jeho detailu.
