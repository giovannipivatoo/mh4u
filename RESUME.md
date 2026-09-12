# Ripresa del progetto MH4U

## Stato della sessione

**Ripresa esplicitamente dall'utente il 2026-09-12.** La precedente pausa risale al
2026-09-11, ore 17:24 circa Europe/Rome. Il runtime era stato chiuso con Command-Q.
Alla ripresa non risultavano runtime, riferimenti o build del progetto attivi.
La verifica Sol delle Preferenze del riferimento è passata. La prova privata ha
recuperato il cappello, risalito corda e sentina ed è tornata sul ponte. L'utente ha
poi chiesto di giocare personalmente e ha spostato il lavoro su controller e schermi.
Non inviare input di gioco mentre l'utente sta giocando; osservare e guidare.

## Aggiornamento controller e schermi — 2026-09-12

Implementati menu Cocoa **Settings → Controller…** (Cmd+,), rimappatura persistente
DualSense per i 14 comandi 3DS, scelta degli stick e **Toggle Lower** (predefinito:
clic touchpad). **Show Lower Screen** (Cmd+B) è il comando alternativo da menu.
Fullscreen superiore 400:240 predefinito; schermo inferiore 320:240 in un riquadro
in basso a destra, touch con mouse. Preferences NSUserDefaults `local.mh4u.runtime`.
Il controllo assegnato al toggle non viene anche inviato al gioco. Pressioni tenute
durante cambio focus/menu/riconnessione devono essere rilasciate prima di riprendere.
Escape esce prima dal fullscreen; in finestra chiude. Green button e menu persistono
la scelta fullscreen. Nessun cambio di renderer PICA.

File nuovi: `src/controller_config.h/.mm`, implementati da Sol; integrazione e crop
Metal in `src/main.mm`. La build firma il bundle locale con codesign ad-hoc.
Test: tutti i 6 gruppi CTest passati dopo la correzione Retina; readback dei pixel
della composizione finale, crop, overlay visibile/nascosto, coordinate touch e
rilevamento pressioni testati. Boot finito 300 frame in `.local/controller-validation/smoke.json`.
CUA ha visto **DualSense Wireless Controller**, menu completo e salvataggio della
scelta R3; ripristinato Touchpad Click. Schermo superiore fullscreen e toggle da
menu osservati. Prova fisica Cerchio/touchpad richiesta all'utente, risposta ancora
pendente; non descriverla come confermata. L'utente ha comunque avanzato al ponte
senza input di gioco inviato dall'agente in questa prova.

Stato della prova corrente: `.local/controller-validation/state` (copia privata).
Processo in `.local/controller-validation/installed-process.json`, limite 36.000
frame e watchdog 900 secondi dal lancio. NON è una sessione normale illimitata.
Controllare processi/exit prima di riaprire; non interrompere progressi dell'utente.
L'app normale mantiene separati i suoi salvataggi canonici. Prova dettagliata in
`.local/controller-validation/report.json`; nessun completamento missione o
salvataggio dei progressi ancora verificato.

**Preferenza esplicita: usare agenti `gpt-5.6-sol` per l'implementazione parallela.**
Leggere `AGENTS.md` e la skill ponytail prima di modificare codice. Non servono
domande all'utente per normali scelte tecniche già autorizzate.

## Obiettivo e architettura

Runtime nativo Apple Silicon specializzato per l'immagine MH4U europea fornita
dall'utente, su M2 Pro / macOS 26.5.2 / SDK 26.5. Non è una riscrittura indipendente
del gioco: riusa Azahar 2126.1, commit `26e608f6fa292b27cda0ae8c84e148d17600a5e6`,
con JIT Dynarmic ARMv6K → AArch64 e servizi 3DS HLE.

Frontend Cocoa Objective-C++, audio AudioQueue, tastiera/touch/GameController.
PICA Vulkan → MoltenVK → readback GPU sincrono → texture Metal → Metal 4FX spaziale.
Fallback MetalFX precedente, bilineare e rasterizzatore software. Nessun backend
PICA→Metal diretto, nessun percorso zero-copy o MetalFX temporale.

App installate:

- `~/Applications/MH4U Runtime.app`, ID `local.mh4u.runtime`.
- `~/Applications/Azahar Reference.app`, ID `local.mh4u.azaharreference`.

Entrambe applicano un sandbox di processo che nega `network*`. Il runtime usa
copie verificate degli input in Application Support per evitare permessi generali
sul Desktop. OpenSSL del runtime resta una dipendenza Homebrew locale: non è un
pacchetto autonomo redistribuibile.

## Input e confini

- Immagine originale di 4 GiB nella root: `Monster Hunter 4 Ultimate (Europe) (En,Fr,De,Es,It).3ds`.
- Originale SHA-256: `3832beef353d134bcba6ef83dc987e7ae228c43dc32a6ba52519f5f103f52581`.
- Titolo `0004000000126100`, prodotto `CTR-P-BFGP`; partizione principale già decifrata.
- CXI `.local/game/main.cxi`, 2.727.489.536 byte, SHA-256 `b60784a71f09135af012817cc4a7c06cd0723131ff590528174aee9057f035c2`.
- Codice decompresso `.local/game/exefs/code.bin`, SHA-256 `63940d7ef1fecc119f9fb820f5f6a2cf2f2a5549e4a70f00319fbd6c9c1ad8dc`.
- RomFS: 11.445 file. ExeFS, hash e tutti i livelli IVFC verificati; firme RSA non verificate.
- Estrattore Python stdlib; `.local/game/manifest.json` e `.local/game-reverify/verification.json` conservano le prove.

Mai cercare/scaricare ROM, firmware, chiavi o asset di gioco; mai caricare gli input
su servizi esterni o inserirli in Git. Non estrarre le partizioni di aggiornamento.
Il checkout sorgente esclude `src/core/hw/default_keys.h` prima del recupero dei blob,
controlla l'esclusione e rimuove gli oggetti Git; `ENABLE_BUILTIN_KEYBLOB=OFF`.

Incidente iniziale già documentato in `docs/reference.md`: artefatti precompilati
Azahar/CTRTool scaricati prima di scoprire le chiavi incorporate furono eliminati;
il precompilato Azahar non fu eseguito e l'header non fu letto. Il percorso attuale
di estrazione/build esclude questi artefatti. Non descrivere falsamente tutta la
storia come priva di quell'incidente.

## Risultati verificati

- Build arm64, estrazione e confini di input; sei gruppi CTest superati.
- Boot JIT e interprete, menu, filmato iniziale e scena 3D della nave.
- Creazione completa di `Native` + `Palico` tramite il frontend nativo, salvataggio
  ordinario, uscita pulita e riconoscimento del personaggio in un processo nuovo.
- Camminata, scale, inseguimento della telecamera, dialoghi/NPC e camera verticale/orizzontale.
- Replay finestra nativa: 7.400 frame, 124,172 secondi, 59,595 frame presentati/s;
  tutti i frame letti via Vulkan e presentati con Metal 4FX. Include avvio, caricamenti
  e movimento iniziale; non è un benchmark di caccia a regime né un confronto A/B controllato.
- Tutorial dei Remobra superato durante la prova interattiva; comparsa e rendering
  di Dah'ren Mohran verificati. Ultima schermata: il Caravaner invita a risalire la
  corda fino alla sentina e usare le scale per tornare sul ponte.

**Non ancora verificati:** completamento dell'incontro/missione, combattimento completo,
salvataggio e ricaricamento dei progressi della missione, controller fisico, qualità
audio ascoltata indipendentemente. Il solo cambiamento dell'hash di `user1` non
prova un salvataggio dei progressi.

## Stato privato da preservare

- Salvataggi normali utente: `~/Library/Application Support/MH4U Runtime/.local/state/Azahar`.
  Nessun personaggio di test è stato inserito qui.
- Riferimento: `~/Library/Application Support/Azahar Reference/`, personaggio `Hunter`.
- Test nativo creato da zero: `.local/native-creation/state/Azahar`, personaggio `Native`.
- Backup alla pausa: `.local/checkpoints/20260911T152420Z/native-creation-state/Azahar`.
  Manifest con hash e metriche: `checkpoint.json` nello stesso checkpoint;
  `.local/checkpoints/latest.json` punta al checkpoint corrente.

**Non è stato creato un savestate della RAM.** L'uscita ha conservato il salvataggio
ordinario, ma il tutorial potrebbe ripartire dall'inizio. Non promettere di riprendere
esattamente dalla corda. Non sovrascrivere i salvataggi normali con quelli di test.

Prove utili:

- `.local/native-creation/validation.json`: creazione e riapertura del personaggio.
- `.local/native-creation/reload.log`, `reload.ppm`: ultima esecuzione interattiva e cattura finale.
- `.local/vulkan/gameplay/report.json`: caricamento, dialogo e movimento in stato isolato.
- `.local/vulkan/pacing-hunter/`: replay finestra, metriche, cattura e provenienza.
- `.local/vulkan/core-build-validation.json`: core corrente SHA-256 `8f565b9e8dffd51c1ff559e503bc43de34a63c0221befdb4d6e369176906994c`.
- `tests/sandship-input.json`: soli eventi controller per arrivare alla prima scena e muoversi;
  richiede un nuovo personaggio con tutorial ancora da svolgere. Vedere `tests/README.md`.

## Correzioni già implementate

- Cache di traduzione memoria condivisa eliminata: risolve il crash del rasterizzatore software.
- Completamento del producer Vulkan prima dell'handoff libretro, che non forniva un semaforo.
- Touch limitato al rettangolo dello schermo inferiore, senza riuso della posizione precedente.
- Tap nativi mantenuti per almeno due frame; perdita del focus azzera gli input.
- Pacing con deadline persistente, conteggi distinti di core/presentazione/eventi/sleep.
- Applicazione patch idempotente: prima reverse dry-run `--force --fuzz=0`, poi forward.
- Sandbox offline e tolleranza del listener UDP opzionale nel riferimento.

Ultimo lavoro Sol: `patches/azahar-reference-passive-microphone-enumeration.patch`
rimuove la richiesta sincrona del microfono durante l'enumerazione delle Preferenze.
Il controllo per la cattura effettiva resta presente. Riferimento compilato, installato
e firma verificata; SHA eseguibile `9d43db42342fd050036011d317f3c8d8392efd1626b9c75ef5358b95d626f30b`.
**Verifica visiva superata il 2026-09-12:** Preferenze e pagina Audio reattive,
nessuna richiesta microfono osservata, nessuna impostazione o autorizzazione cambiata,
uscita pulita. Prova: `.local/reference/preferences-validation-20260912.json`.
La cattura effettiva del microfono non è stata provata.
Il test testuale ridondante aggiunto inizialmente dall'agente è stato rimosso.

## Prossimi passi alla ripresa

1. Completato: Preferenze/Audio riferimento verificate con CUA senza nuovi permessi.
2. Riprendere su una copia privata del salvataggio `Native`; completare il tutorial,
   arrivare a un punto di salvataggio ordinario e verificare i progressi dopo riavvio.
3. Solo dopo, approfondire combattimento, missioni e prestazioni in scene riproducibili.
   Evitare altre ottimizzazioni senza misure o bug concreti.

Comandi disponibili:

```sh
python3 tools/mh4u.py install
python3 tools/mh4u.py verify --frames 300 --compare
python3 tools/build_reference.py --install --test-input
```

CUA: usare il percorso completo dell'app, perché più bundle condividono l'ID nativo.
Tasti nativi: A=`k`, B=`j`, X=`i`, Y=`u`, Circle Pad=`WASD`, D-pad/fotocamera=frecce,
L/reset camera=`q`, R=`e`, Start=`Return`. Il tutorial Remobra richiede camera al limite
superiore e rotazione finché lo stormo entra nell'inquadratura; la sola camera alta
con orientamento sbagliato non basta. In CUA i tap brevi possono essere ripetuti in
batch, poi osservare di nuovo la schermata. Non usare altri sistemi di input OS.

Prima della pausa il progetto aveva il commit locale `971962c`; il checkpoint di pausa
include anche documentazione, replay e ultima patch Sol. Nessun remoto/push effettuato.
