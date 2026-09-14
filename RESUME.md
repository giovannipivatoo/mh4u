# Ripresa del progetto MH4U

## Implementazione AOT + Metal in corso — 2026-09-15

Branch locale/remoto `feat/apple-silicon-aot-metal`; lavoro utente autorizzato,
implementazione delegata a Sol, revisione read-only Astra. Stato e comandi in
`docs/aot-metal.md`. Le nuove opzioni CMake costruiscono moduli sperimentali:
il runtime giocabile e l'app installata restano JIT/Vulkan.

Checkpoint sorgenti `32d95a8` pubblicato nel branch. Lavoro successivo ancora in
corso: generazione oltre SVC, exclusive32/FPSCR/sign-extension/BIC con confronti
dedicati, e adapter CoreRasterizer Metal compilabile. Core Metal isolato in
`.local/pica-metal-core-source`/`-build`, patch sperimentale esplicita. Il primo
crash era un layout RendererSoftware diverso fra translation unit: membro
condizionale prima di ScreenInfo, macro assente in citra_libretro_common. Layout
ora invariante. Repro env Metal OFF: 300 frame PASS. Metal ON: arresto esplicito
al primo DrawTriangles per scritture depth/stencil non esportabili; 0 draw Metal,
nessuna prova di game frame nativo. Prossimo slice: import/export depth/stencil.
Root build combinata aggiornata e 36/36 CTest PASS. Non scambiare questi progressi
in corso per il contenuto già verificato del checkpoint pubblicato.

Checkpoint Metal `d7cb7c4` pubblicato. AOT successivo stabilizzato: 16/16 test
dedicati PASS; artifact core512 con entry FPSCR03c00000 e continuation03000000.
Manifest512 blocchi/1748 fetch/6900 IR, frontier62, indirect113, coveragefalse.
Smoke reale: SVC iniziale, poi43 ulteriori blockcallback, MissingBlock0x1067ec
con CPSR60000010/FPSCR03000000, identity verificata, zero frame/no timeout.
Prossimo slice AOT: aggiungere entry osservate offline e ampliare copertura con
gli stessi limiti/fault espliciti; nessun JIT fallback.

- Sol `sol_port_first_step` possiede `src/aot`, `tools/aot`, `tests/aot`,
  `cmake/Aot.cmake` e CMakeLists.txt. Generazione persistente Dynarmic IR→C++→runner
  senza Dynarmic, differenziali ARM/Thumb e matrici registri/shift. Catena reale
  di 62 blocchi fino alla prima SVC a PC 0x107328: 477324 tick, confronto JIT
  uguale per registri, memoria e timing. Mapping e callback SVC sintetici:
  non è boot del kernel. Adapter ARM_Interface implementato nel core separato
  `.local/aot-core-source`/`-build`, con fault fatali e nessun fallback JIT.
  Smoke reale fresco PASS per arresto atteso: verifica identità istruzioni,
  prima SVC HLE, poi MissingBlock 0x00107328; zero frame e nessun timeout.
  Patch riproducibile `experimental-aot-core-adapter.patch`, helper build/smoke
  in tools/aot. Prossimo slice: generazione oltre frontiera SVC e nuovo differenziale.
- Sol `sol_metal_renderer` possiede `src/pica_metal`, `tools/pica_metal`,
  `tests/pica_metal`, `cmake/PicaMetal.cmake` e la patch
  `patches/experimental-pica-metal-batch-trace.patch`. Due test GPU passati:
  draw multipli con depth, texture/TEV, quantizzazione D16 e adattatore PICA reale.
  Il riferimento TEV è il renderer accelerato pinned, non parità hardware provata.
- Core trace separato in `.local/pica-metal-trace-source` e relativo `-build`,
  keyblob OFF e header escluso assente. Smoke finito 600 frame su stato NUOVO,
  otto batch reali catturati. Implementati D24S8/stencil, scissor e blend copy
  osservati: replay v1 3/8 renderizzati, altri 5 richiedono texture catturate.
  I batch iniziali sono neri: non provano schermate visibili né gameplay.
  Trace v2/v3 aggiunge texture limitate e flush della cache GPU prima della copia;
  v3 verificato: flush sincrono corretto, 8/8 batch accettati ma neri/quasi neri.
  Replay isolato usa clear sintetici: nessuna equivalenza con il frame originale.
  Finestra 64–71 rifiutata per ETC1A4/proctex. Target persistente implementato:
  create/import colore, draw con LoadActionLoad, readback; test submission separate
  mantiene depth. Import/export depth/stencil e adapter guest-address/core mancanti.
  Ultimo retest root dedicato AOT/Metal: 11/11 PASS.
  Provenienza e dati privati in `.local/pica-metal-trace/`; texture non catturate
  nella versione iniziale del trace. Nessun salvataggio canonico usato.

Root possiede documentazione e build `.local/aot-metal-candidate`; build riferimento
`.local/aot-metal-baseline` passa 19/19 test e smoke300 con298frame non neri.
Build combinata aggiornata: 30/30 CTest passati, inclusi nove AOT e due PICA Metal.
Le nuove prove non attestano ancora MH4U eseguibile con AOT e Metal diretto.
Preservare il lavoro nel branch: non è ancora un port completo né un aggiornamento
dell'app installata. Prima di riprendere verificare agenti/processi e gli ultimi
risultati, perché questa nota fotografa un'implementazione ancora attiva.

## Direzione port approvata — 2026-09-14

L'utente ha scelto AOT prima dell'avvio e renderer PICA→Metal, riusando inizialmente
kernel e servizi HLE derivati da Azahar. Vuole poter riscrivere anche le parti
rimanenti in futuro: mantenere sostituibili i punti d'integrazione concreti.
Prima di implementare CPU AOT, renderer o sostituzioni HLE, leggere
`docs/architecture.md`, sezione "Accepted port direction", per i vincoli concordati.
È una decisione per il lavoro successivo: l'app installata resta JIT/Vulkan e la
fattibilità della copertura AOT completa deve ancora essere verificata.
Sol `sol_port_first_step` ha un incarico preparatorio read-only sulle API di
traduzione e confronto; Astra `astra_port_review` ha un incarico di revisione
architetturale. Nessuna implementazione AOT o Metal diretto è attestata da questa nota.

## Follow-up audio Steppa e menu installato — 2026-09-14

Ulteriore segnalazione utente: ritardi nei cambi zona della Steppa e rumore/ripartenze
durante hover dei menu, senza pausa. Tre agenti Sol high hanno completato buffer,
integrazione audio e scheduler menu; root ha revisionato, validato e installato.
Questa sezione supera la policy FIFO 1024 del checkpoint sottostante.

- FIFO limitata a 2048 frame stereo (~62,6 ms, non latenza totale), ripartenza
  dopo 1024 frame disponibili e transizioni di 64 frame verso silenzio/ripresa
  e sui tagli overflow. Conserva i campioni recenti, evita ripartenze frammentate.
- Contatori espliciti underrun/recovery/drop/gap; priming iniziale escluso.
  Pause→Start e protezione teardown preservati; otto cicli impostazioni audio
  più starvation intenzionale coperti dal selftest.
- Timer menu Cocoa rischedulato su deadline assoluta, senza polling aggressivo,
  per evitare il salto di un intervallo dopo un frame lento.

CMake build e 19/19 CTest passati, inclusi device e input. Probe buffer copre
fade/rebuffer/overflow e 600 tick regolari senza perdita; agente: ASan/UBSan PASS.
Replay reale Steppa campo→prima area, 800 frame, New3DS 4×, cache shader calda,
texture custom disattivate per confronto: underrun 102→5, drop 9920→3264,
zero errori AudioQueue. Non è prova dell'intera configurazione con pack HD né
di ascolto umano. Caricamenti/shader realmente bloccanti possono ancora causare
un breve silenzio: il frontend non può inventare audio non prodotto dal core.
Menu reale a 4× con stesso nuovo buffer: scheduler precedente 1 underrun/1664
frame mancanti, nuovo 0/0; massimo tick 33,99→20,96 ms nel test delimitato.

Installato `~/Applications/MH4U Runtime.app`, firma verificata, payload identico
alla build testata; SHA host `1458135d2b49c4b7f7af66f111c49f689760730226053bac825ac045899445a5`.
Backup recuperabile `.local/audio-zone-20260914/previous.app`.
Manifest canonici di ENTRAMBI i profili invariati rispetto all'inizio di QUESTO
follow-up. Il vecchio manifest runtime-fixes precede il gioco dell'utente fra
le due richieste e non va usato per ripristinare i suoi progressi successivi.
Evidence `.local/audio-zone-20260914/`, menu `.local/fixes-menu-game/ab-4x-summary.json`.
Core37, ROM, asset e salvataggi non modificati.

## Cinque correzioni audio/menu/touch installate — 2026-09-14

Richiesta utente completata con cinque agenti `gpt-5.6-sol`, reasoning high,
in due ondate per il limite di tre collaboratori simultanei. Root ha integrato,
revisionato e installato il frontend. L’utente ha confermato che il gioco era chiuso.

- `present()` evita `nextDrawable` quando la finestra è nascosta/minimizzata/occlusa,
  così quell’attesa non ferma il produttore audio sul thread del gioco.
- Backlog software audio massimo 1024 frame stereo (~31 ms alla frequenza del core;
  NON latenza totale di uscita). Overflow conserva i campioni recenti, stereo e
  silenzio in underflow verificati. Re-enqueue fuori dal mutex.
- Ripresa audio con Pause→Start, senza Reset che poteva svuotare i buffer primed;
  transizioni idempotenti, errori controllati. Teardown esplicito impedisce alle tre
  callback di flush di reinserire i buffer durante Dispose. Avvio audio anche nella
  transizione `--window-start`.
- Menu: NSTimer nel solo NSEventTrackingRunLoopMode esegue la stessa closure
  `runFrame` sul main thread. Protezioni reentrancy/eccezioni/limite finito,
  telemetria `menu_tracking_frames`; pannelli e pausa manuale restano intenzionali.
- Touchpad relativo con baseline per contatto, gain X .75/Y .50, clamp, clutch
  senza salti, reset baseline su focus/disconnessione/settings/overlay. R3 invariato.
  Fallback GameController legacy senza touchState conserva l’ambiguità di (0,0);
  il percorso moderno usa touchState. Nuova prova fisica del controller non eseguita.

Build CMake Release arm64 e **19/19 CTest passati**, inclusi device Metal,
input relativo, policy audio, otto cicli audio e menu Cocoa reale. Agente audio:
dieci ripetizioni del test finale, tutte passate, zero errori anche dopo Dispose.
Root ha scoperto e fatto correggere tre errori di teardown nel primo smoke;
i report finali candidate/installed hanno `audio_queue_errors=0`.

Replay reale 900 frame dal checkpoint privato second-carry, audio abilitato,
load120, scena finale identica ai precedenti replay del colpo di cannone.
Candidate occluso: 0 presentazioni ma 900 frame renderizzati dal core e 484384 frame
audio consumati. Installed: 12 presentazioni, 484416 frame audio consumati,
1021 callback; niente benchmark di FPS o ascolto indipendente dell’audio.
UI su bundle di prova separato: mute→unmute e volume65 osservati, 5403 core.run;
le azioni AX aprono il menu asincronamente e non attivano il tracking annidato.
Per verificare quel percorso, Sol ha compilato variante PRIVATA con solo trigger
automatico NSMenu a run300: 600 core.run, 40 durante menu, 598 video non neri,
323040 frame audio consumati e zero errori. Shipping source SHA confrontato.

Installato `~/Applications/MH4U Runtime.app`, firma valida e payload senza firma
identico alla build verificata. SHA eseguibile:
`85d6a13f24ced83c9d90784ddde172f709e3fc3afd07ddd5ddb7ee92d3bc3862`.
Backup app: `.local/runtime-fixes-20260914/previous.app`.
Anche bundle build aggiornato. Core e manifest SDMC/NAND/sysdata di ENTRAMBI
i profili canonici invariati. Nessuna modifica a ROM, core, asset o salvataggi.
Report root `.local/runtime-fixes-20260914/final.md`, `installation.json`,
`installed-report.json`, `ctest.log`; prova menu `.local/fixes-menu-game/report.json`.
Tutti i processi di verifica root sono terminati; nessun gioco lasciato aperto.

## Consegna runtime e prossime prove utente — 2026-09-14

Obiettivo iniziale raggiunto nel ramo runtime di ricompilazione specializzato:
app arm64 installata, JIT/HLE, Vulkan PICA→MoltenVK→Metal/MetalFX, input DualSense,
salvataggi, missioni di raccolta, colpo di combattimento ripetibile e misura in
finestra verificati. Non è un port diretto del renderer PICA in Metal, né una
certificazione di ogni caccia. Audit finale locale verificato da root:
`.local/runtime-acceptance-audit/final.md`. I checkpoint sottostanti che dicono
obiettivo ancora attivo o sottoagenti ancora in lavoro sono storici; nessun job
di implementazione resta pendente. Le modifiche autorizzate sono nel worktree,
non è stato eseguito un commit generale.

L’utente chiede quali prove fare personalmente. Priorità: avvio ordinaryContinue
nell’app installed, stessa caccia completa + ritorno al villaggio + seconda
partenza verificando C-stick/ZL/ZR/avvisoCPP; touchpad/R3 e overlay durante menu
e missione; ordinarySave/quit/relaunch controllando oggetti/equipaggiamento;
riportare difetti grafici, audio e rallentamenti con missione/zona/azione precisa.
Non servono upload di ROM o salvataggi, installazioni o test tecnici manuali.

## Combattimento ripetibile e misura in finestra — 2026-09-13

Sol ha riutilizzato il checkpoint locale core37 del tutorial `second-carry`
in `.local/quest-corrected-20260913/snapshots/`: sequenza di 8 input porta al
colpo di cannone e al dialogo del Caravaneer che conferma il colpo al mostro.
Due replay da 900 frame hanno catture finali identiche; non si dichiara kill,
carve o completamento dell’intero incontro. Report
`.local/combat-validation-20260913/report.json` con input e hash di provenienza.

Telemetria minima `paced_*` aggiunta da Sol, usando intervalli esistenti per
escludere bootstrap headless dai tempi in finestra. Build CMake separata con
17/17 CTest passati, test reale window-start120:180 produce esattamente60frame
paced. Root ha verificato il payload senza firma identico al testato e installato
il frontend aggiornato in entrambi i bundle. SHA installed finale:
`b49278f2cc27e110c90cdd76d87c8f8b09f5132ec6f84d57ee0de84306b3c0b2`.
Backup app pre-telemetria `.local/install-integration-validation/pre-pacing.app`.

Replay nell’app installed con librerie/game privateSupport e stato CLONATO:
900 frame totali, load120 escluso dalla misura, finestra150..899. 750presentazioni
Metal4/MetalFX, 12,53198s paced, 59,8469FPS di submission, 7frame oltrebudget,
maxlavoro40,982ms. Risoluzione1×, texturecustom/audio/temporale disattivati.
Cattura finale IDENTICA ai due replay headless e ispezionata da root.
Non sono prestazioni universali né una caccia lunga; è un tratto misurato del
tutorial con trasporto, movimento e colpo. Savedata canonico invariato.
Report `.local/install-integration-validation/paced-combat-report.json`;
comando, metriche e catture nella stessa directory. L’installazione precedente
è valida per migrazione e ordinaryContinue; il suo hashhost313c è ora storico.

## App e profilo unificati — 2026-09-13

Installazione completata e verificata. Entrambi i bundle Cocoa e il launcher
usano ora `~/Library/Application Support/MH4U Runtime/.local/state` per default.
Il CLI senza bundle conserva il default workspace; `--state-dir` esplicito prevale.
Il profilo workspace corretto per CPP è stato migrato solo perché quello
installato non aveva alcun user1/2/3. Copiato atomicamente l’intero SDMC
(savedata + extdata), sotto lock di entrambe le sessioni e controllo hash;
workspace invariato. Tutti gli altri file Azahar installati restano identici,
incluso il texture pack da 11 GB, NAND e sysdata. Vecchio SDMC verificato in:
`~/Library/Application Support/MH4U Runtime/.local/state/profile-migration/backups/20260913T163011.407678Z/sdmc`.
Vecchia app: `.local/install-integration-validation/previous.app`.

Frontend installato SHA313cbe510e63d97b6e8c0ec60a84a6451921b69a3e306f878537ced9510608a8,
core37 invariato. CMake Release arm64, firma verificata, 17/17 CTest e
10 test sintetici migrazione passati. Routing del bundle verificato con lock
profilo privateSupport e override su copia. Avvio installed su copia:
6.600 frame, 6.598 non neri, zero RAMload, 600 presentazioni Metal4/MetalFX;
cattura del villaggio ispezionata, stesso personaggio/equipaggiamento.
Report completo `.local/install-integration-validation/report.json`;
`installed.json`, `mixed.json`, `.local/app-routing-validation/report.json`.
Il report CPP precedente che dice privateSupport invariato è storico: adesso
anche l’app installata usa la correzione. Per giocare usare Continua ordinario.

L’obiettivo generale resta attivo. Sol_cpp_idle_check sta cercando un incontro
ripetibile in `.local/combat-validation-20260913`; finora Area1, non ancora
combattimento dimostrato. Sol_circle_pad_disconnect aggiunge telemetria minima
per isolare i tempi dei frame in finestra dal bootstrap headless: possiede
src/main.mm e tests/README.md finché termina. Root ha completato installazione
precedente, non riavviato alcuna partita utente. Nuova telemetria da verificare
prima di eventuale aggiornamento frontend. Non confondere FPS di bootstrap con
prestazioni in combattimento; audit `.local/runtime-acceptance-audit/report.md`.

## CPP corretto nel profilo della partita — 2026-09-13

**COMPLETATO e applicato**, senza patchcore. Profilo effettivo usato dalla partita:
`/Users/giopiz/Desktop/mh4u/.local/state`, NON il distinto profilo privateSupport.
Anche questo profilo carica CPPOn/ButtonsFF, confermato da clone read-onlySol.
Root ha copiato i salvataggi sottoStateLock, usato esclusivamente menuOpzioni
(Type4→Type1→Type4) e QuitGame→Save su quella copia; nessuna missione o movimento
eseguiti nella copia del profilo utente. Un passaggio errato ha aperto solo Palico
Status, poi annullato; nessuna opzione Palico o progresso modificato deliberatamente.

Raw4 riparati congelati in `.local/cpp-user-repair/validated-raw` e verificati
su due copie con EXTData ORIGINALE: core normale e diagnostico,6.000frame,0RAMload
ognuno. Entrambe riaprono il villaggio con stesso personaggio/equipaggiamento;
traccia conferma7d1/7e3. Quindi bastano rawsavedata, senza sostituire extdata.

Applicazione eseguita dal piccolo helper PRIVATO Sol, compilatoCMake, che riusa
SaveImport::StateLock/stage/activatePending. Dry-run passato; sotto lock ricontrolla
l’intero SDMC controil manifest originale, poi fa backup e RENAME_SWAP atomico.
Test sintetici: dry-run, lockoccupato, backup, preservazionealtrifile; root ha
verificato inoltre rifiuto manifestobsoleto senza alcuna modifica. Applicazione
uscita0 e post-verifica completa: cambiano SOLOsystem euser1, user2/user3 edextdata
identici agli originali, nessun pendingimport. Backup verificato:
`.local/state/save-import/backups/1789315618914971-42145/data/00000001`.
Backup SDMC integrale aggiuntivo: `.local/cpp-user-repair/original-sdmc`.

Report finale `.local/cpp-user-repair/final-report.json`, `applied.json`,
`post-application-manifest.json`; reportdiagnosiSol aggiornato. Core37, app eprofilo
installedprivateSupport invariati. L’avvio normale Continue usa il salvataggio
corretto; vecchi RAMsavestate conservano la configurazione precedente e possono
reintrodurre il difetto. Non caricarli pervalidare la correzione.

Regressione verificata a core37: DUEHarvestricomplete, seconda dopoordinarysave e
freshContinue, zeroDisconnect/Finalize a entrambe le ricompense; C-stickdestro
ruota la camera nella seconda. Queste erano copie di prova; nessuna di quelle
missioni è stata inserita nel profilo utente. Correzione ebackupactuali completati.
L’obiettivo runtime generale resta attivo; questo bug specifico è risolto.

## Ultimo checkpoint CPP — selettore del salvataggio, 2026-09-13

La causa del replay fallito è stata individuata: il salvataggio fornito carica
CPP On (+7d=1) ma CPP Buttons con valoreFF (+7e), visualizzato come Type4. A fine
missione il getter ritornaFF e il gioco disattivaCPP. Non è un difetto dimostrato
della notifica IR; nessuna patchcore va promossa. Off→On cambia solo7d e NONrisolve.

Correzione tramite normale UI: Opzioni pagina3, CirclePadProButtons,
Type4→Type1→Type4, conferma e salvataggio ordinario; attivareCPP seOff.
Root ha applicato SOLOquesta modifica su copia privata core37: missione
camp→ricompense15.710frame77,903s, zeroDisconnect/Finalize (baseline2+1), poi
salvataggio e ritorno villaggio. FreshContinue6.000frame senzaRAMload passato.
Sol ha caricato quel save ordinario con diagnostica: +7d1,+7e3; la correzione
persiste. `mode-save-bootstrap.log` righe22549-50; `final-report.md` nella cartellaSol.

Seconda missione dopoFreshContinue accettata e partenza visivamente verificate.
ProveC-stick450frame idle/destra su copie mostrano rotazione netta della camera.
Seconda missione camp→ricompense conclusa:15.710frame88,172s, zeroDisconnect
eFinalize, cattura ricompense ispezionata. Report completo e7controlli in
`.local/cpp-mode-validation/report.json`. Solmain verifica inoltre una COPIA degli
attuali save canonici per distinguere problema delseed da stato attualeutente;
Solidle verifica salvataggio tramiteQuitGame su propria copia privata.
Nessun profilo utente, app o core modificato finora. README include rimedio preciso.
ATTENZIONEprofili: build/MH4URuntime.app usa MH4UWorkspace=workspace e
`.local/state` contiene i4saveutente. ~/Applications bundle usa privateSupport,
che al controllo attuale contiene solo system nella directorysavedata. Non dare
per scontato che privateSupport sia il profilo della partita riferita; preservare
ENTRAMBI e non sincronizzare/copiarli alla cieca. Solmain diagnostica cloneworkspace.
QuitGame saveworkflow verificato daSolidle senzaquest: Menu2UPdaStatus→QuitGame,
A, LEFT/A perExitYes, A perSaveYes; ordinarysave eFreshContinue passati.
Report `.local/cpp-quit-validation/report.json`.
Le sezioni storiche sotto sulla ricerca di un clear7d sono superate da questo dato.

## Trasferimento fotogrammi ottimizzato e installato — 2026-09-13

Root ha completato la modifica iniziata da Sol: il callback Vulkan trasferisce
il vector BGRA al frontend; `finishVideo` condivide contatori/presentazione, mentre
`vulkanVideo` evita copia completa e riscrittura alpha già opaca nel bridge.
La ricerca di pixel non neri termina al primo colore. Percorso software conserva
pitch e normalizzazione alpha. Nuovo `--video-self-test` / CTest `native-video`
verifica nero opaco, pixel finale a 4×, riuso buffer producer, downscale e duplicati.

Build Release arm64 `.local/frame-transfer-build`, **17/17 CTest passati**.
A/B finito 1.200 frame a 1× e 4×: catture finali identiche byte per byte alla
baseline. Replay reale 1→4→1 con temporale: 360 frame, 358 non neri, 204 temporali,
zero rifiuti allineamento; catture ispezionate. Tempi headless non isolati dal
carico della macchina: non dichiarare miglioramento FPS. Il microbenchmark della
precedente variante copy-only misurava ~0,3 ms di CPU risparmiati a 4×, non FPS.

Installato SOLO frontend testato in `~/Applications/MH4U Runtime.app`, staging e
rename, firma verificata, payload codice senza firma identico al testato (SHA
`b3a6d3e91661b2c296ce7c5b0ddf16ce0454b34de33e1d0687c720da7c4cc370`).
Core37 e 20 file savedata canonici invariati. Backup app precedente in
`.local/frame-transfer-validation/previous.app`. Nessuna sostituzione del bundle
build/ attivo e nessun riavvio della partita utente. App installata verificata
anche su stato isolato con percorsi runtime privati predefiniti: 300 frame a 4×,
298 non neri, un load corretto. Core SHA e compatibilità snapshot invariati.

Report `.local/frame-transfer-validation/final-comparison.json`,
`final-ctest.log`, `final-temporal.json`, `installation.json`, `installed-report.json`.
Il binario include l’estensione di replay C-stick dell’agente CPP, già testata;
NON include una correzione del problema CPP. Modifiche ancora non committate,
preservare le molte estensioni autorizzate delle altre sessioni nel worktree.

## Disconnessione Circle Pad Pro dopo missione — indagine attiva 2026-09-13

L’utente precisa: al ritorno al villaggio compare «circle pad pro disconnected»,
mentre gli altri tasti continuano a funzionare. Il DualSense fisico resta operativo.
Sol `sol_circle_pad_disconnect` ha riprodotto la perdita della sessione IR/CPP:
il C-stick risponde prima della missione; dopo Disconnect/Finalize richiesti dal
gioco non compare una nuova Initialize/RequireConnection. Anche entrando in una
seconda Harvest Tour senza ripristinare snapshot precedenti, C-stick destro e due
prove ferme producono la stessa immagine. È evidenza di mancato recupero della
sessione, non ancora una correzione. Artefatti `.local/circle-pad-disconnect-validation/`.

Ipotesi ClearReceiveBuffer/ClearSendBuffer smentita: il dispatcher non implementato
restituisce già ResultSuccess. Patch ritirata e rimossa; il vecchio candidato
software-only NON va installato. Il replay `cstick` (analog index1), con verifica
input/range, è incluso nel frontend installato e serve ai test isolati.

Esperimento attuale Sol: sorgente privata ripristinata dal core corretto37,
poi omessa SOLO la notifica conn_status_event in IR_USER::Disconnect.
Build privata Vulkan ON, OpenGL OFF, built-in keyblob OFF e ABI temporale presente;
smoke ordinario di 300 frame passato. Prima navigazione candidata divergente:
clonato erroneamente lo stato post-completamento, al segmento17 risultava attiva
Advanced: All in Its Place invece di Harvest. Batch fermato; ripetere dal seed
originale `.local/save-import-validation/state`, solo Azahar/sdmc,nand,sysdata.
Seconda prova candidata da seed originale, menu corretti visivamente: raggiunta
QUEST COMPLETE e ricompense; ancora due Disconnect + Finalize. Quindi omettere
conn_status_event non impedisce il teardown ed è escluso dalla promozione.
L’agente deve completare il controllo villaggio/missione successiva e poi tracciare
il primo Disconnect (contesto guest/tempi/polling), senza nuove patch speculative.
Rigenera snapshot dal salvataggio ordinario: mai bypassare il controllo SHA.
Root ha ricostruito 46 segmenti riusciti in
`.local/harvest-route-reconstruction/route.json`: slot2 coincide con accept-harvest,
slot5 con depart-action (hash confrontati). Scartare i rami di navigazione falliti.

Sol `sol_cpp_idle_check` verifica separatamente inattività oltre cinque minuti
contro impulsi C-stick, usando core37 e stati privati `.local/cpp-idle-validation/`.
Conclusa: entrambe le branche 18.720 frame effettivi dopo i load (312 secondi
nominali), nessun teardown IR o avviso. La scena di villaggio non permette di
verificare visivamente la risposta C-stick: non dichiarare CPP funzionante per
questa sola prova. L’inattività da sola non riproduce deterministicamente il bug.
Root esegue anche il percorso ricostruito in un solo processo da salvataggio
ordinario, zero load RAM, `.local/cpp-continuous-baseline/`: serve a distinguere
la transizione di missione dagli effetti del ripristino di snapshot. Risultato
ispezionato: 39.050 frame, uscita0, sorgente invariata, ma navigazione divergente
ancora al banco missioni Advanced: Moving Mountains. Non prova fine missione.
Root adatta il percorso da questa copia isolata, con nuovi snapshot core37;
la sequenza ricostruita non è affidabile senza controllo visivo dei menu.
Root ha poi corretto i menu e raggiunto il campo Harvest; probe 450 frame neutro
contro C-stick destro (270 frame attivi) mostra rotazione visibile della camera.
Da quello spawn, replay camp-complete di 14.710 frame con un solo load iniziale,
nessun load intermedio, mostra QUEST COMPLETE. Altri 500 frame con input vuoto
mostrano le ricompense e producono due Disconnect + Finalize. Fine missione
riprodotta quindi anche senza tasti premuti durante la transizione. È una sequenza
segmentata dal salvataggio ordinario; non confonderla con il primo replay completo
divergente. Root è tornato al villaggio e ha verificato direttamente nelle opzioni pagina3:
Circle Pad Pro = Off. Riattivazione privata con A, scegli Yes (LEFT,A): popup
«The Circle Pad Pro has been activated», valore On, nuovi Initialize/Require
per calibrazione e polling normale nei log. È recupero tramite menu verificato,
non fix automatico; nessun avviso disconnected catturato in questo replay root.
Percorso menu: START→RIGHT (menu2), DOWN×5→A (Options), RIGHT×2 (pagina3),
DOWN×3→A (CPP), LEFT→A (Yes). Report `quest-cpp-report.json`; snapshot finale
slot9 è ora nelle opzioni con popup activated, i checkpoint precedenti sono
conservati per nome. Non attribuire successo di una nuova caccia a questa prova.
Core/installazione e salvataggi canonici non modificati.

## Traccia dei chiamanti CPP — continuazione 2026-09-13

PROGRESSO verificato: due ipotesi IR scartate, caller reale individuato, controllo
senza load alla transizione completato, opzione ON prima/OFF dopo confermata.
Nessun fix CPP installato; il core normale resta SHA37. Non segnare goal completo.

Root usa Capstone5.0.6 in venv privata `.local/cpp-code-analysis/venv` sul solo
code.bin locale. Script `analysis.json`, `disasm.py`, `xrefs.py`, `trace-callers.py`.
Wrapper IPC Disconnect47e230 (SVC47e248), wrapper riscontro47c05c.
Routine SDK47cd30 esegue volutamente DUE Disconnect (47cd48/47cdb4) intorno a
ClearReceive/Send e poi Finalize: non sono un secondo handler svegliato per errore.

Sol ha raccolto tracecore da ordinary save, SHA non bypassato:
`candidate-results-stack.log`, primo stack return47c064→47cd4c→485b64→5b7174→65c1a4.
PC47e24c,LR47c064,SP0fffdae0,thread212,ticks155299423019;
inputobject081d0120,+300=0,+308=1. In 65c028 il gioco chiama2b0044, che ritornaFF
se optionobject+7d==0; FF porta a65c1a0→5b7104(false). Il ramo indica ritornoFF, ma questo può significare +7d==0 OPPURE +7e==FF
con +7d!=0: la sola traccia non prova che +7d sia già0. input+308 è ancora1.
Servono valori diretti di entrambi i byte al Disconnect; non giustifica patch IR.
Global option-object pointer identificato tramite fp in0x00fb6b7c;
input-object pointer0x010572d8, SDKstatebyte0x01064b53.

Root ha eliminato il dubbio load a finequest: da spawn valido core37, un solo
load iniziale e15.710frame nello STESSOprocesso, camp→QUESTCOMPLETE→ricompense.
Uscita0, cattura ricompense ispezionata; ancora dueDisconnect+Finalize.
`.local/cpp-continuous-baseline/no-transition-load.*`, stato without-result-load/.
Controllo menu originale prequest slot1 SHA09ef:1940frame, screenshot
`prequest-option.png` mostra CirclePadPro ON. Non era già Off nel seed originale.

Sol idle analisi in `.local/cpp-idle-validation/static/guest-connected-flow.txt`:
report CPP tipo10 accettato imposta connected a COSTANTE1; response.unknown del
core NON è la causa e NON va cambiato. Read vuota/timeout non sovrascrive+308.
Fallback per SDKstate!=4 lo azzera; riparazione atrue richiede featuremask8,
owner+221 eSDKstate3/4. SDK4=primo report pubblicato; SDK5=worker ricezione terminato,
causa collassata (timeout/limite/stop/errori). Ipotizzare causa concreta solo dopo
traccia. Possibile loss-handler2b1e54 verifica+7d/+308, messaggio1d, disabilita,
poi clear7d; equivalente inline2b5ba4. Caller effettivo del clear ancora da catturare.

Tentativo root LLDB read-only su processo PRIVATO in cpp-code-analysis/watch/
si è fermato all’autorizzazione interattiva macOS prima di eseguire il gioco.
Processi test/debugserver terminati, lldb uscito1; nessun watchpoint osservato.
CUA ha rifiutato accesso a com.apple.SecurityAgent per protezione di sistema;
non aggirare, non toccare autenticazioni. Utente informato di annullare l’avviso
se rimasto aperto. I valori degli offset nel file inspect.py sono validi solo per
core37, derivati disassemblando codice locale, ma il tentativo NON li ha validati.

TASK ATTIVO Sol main: nuova build diagnostica privata Dynarmic senza page_table
veloce, per osservare nei MemoryWrite8/16/32 le transizioni di option+7d,
input+308,SDKstate, con PC/LR/SP/stack. Rigenerare ordinary-save/replay e RACCOGLIERE
il writer effettivo, non fermarsi al build. Ownership solo cartella privata
`.local/circle-pad-disconnect-validation/`; nessuna patch di produzione proposta.
Root mantiene docs/static/private watch artifacts. Tutti i dati di gioco ignorati.

## Localizzazione disattivazione CPP — controlli aggiuntivi 2026-09-13

Root ha ispezionato due controlli menu su snapshot core37 validi:
Circle Pad Pro è **On sia dopo accettazione Harvest nel villaggio sia al campo
subito dopo la partenza**. Cartella `.local/cpp-option-stages/`, `report.json`,
`accepted.png`, `camp-options-page3.png`. Nel menu2 in missione Options è indice3,
nel villaggio indice5; la prima prova in missione apriva Abandon Quest, annullato
con B senza confermare. Non usare quella prima cattura come stato delle opzioni.

La build diagnostica Sol con callback scrittura funziona: bootstrap registra
option+7d 0→1 durante la copia2ff0f0, LRb7d150 (copia32byte a option+64 dalla
configurazione caricata global+cbd0). Registra anche SDK0→2→3→4 e input+3080→1.
Manca ancora la transizione inversa determinante: attendere la cattura 1→0 e
analizzare il chiamante prima di proporre modifiche. Sol main prosegue replay;
Sol idle esamina privatamente i possibili reset/copie dell’opzione. Nessun core
diagnostico installato, nessun nuovo fix CPP e nessuna modifica ai save canonici.

## Esito replay con callback CPP — 2026-09-13

`candidate-camp-nogap-watch2` Sol: 15.710 frame, 130,217s, un load iniziale e
un save finale, ricompense ispezionate da root. Primo tentativo120s scaduto;
secondo con limite300s concluso normalmente. Ancora dueDisconnect+Finalize.
SDK4→5 avviene DOPO il primoDisconnect; input+3081→0 DOPOFinalize. In questa
prova la terminazione worker è quindi conseguenza del teardown, non suo innesco.
Nessuna scrittura option+7d1→0 osservata; tutte le watchlog mostrano solo bootstrap
0→1. Non dedurre una causa dal dato mancante. Estendere diagnosi a pointer globale
opzioni (tutti32bit), option+7e e valori diretti alDisconnect; controllare anche
lo stato iniziale della copia diagnostica e la copertura MemoryWrite64. VSTM
single-reg del reset2b1538 emette WriteMemory32 nella versioneDynarmic locale.

Ulteriori candidati statici Sol idle: reset2b1538 copia default32byte con byte19=0,
caller5f83d0/b73054; setter2b1500 può scrivere+7d con indice19. Solo candidati,
nessuna prova che siano intervenuti. Nessuna correzione CPP pronta/installata.

## Valore opzione CPP trovato nel seed — 2026-09-13

NUOVA EVIDENZA: `finalwatch-bootstrap.log` nella cartella Sol mostra la stessa
copia2ff0f0/LRb7d150 che carica **option+7d=1 e option+7e=FF** dal salvataggio
ordinario. Perciò il getter2b0044 ritornaFF anche con On; non serve alcuna scrittura
7d1→0 per spiegare il ramo65c1a0. Non cercare più un presunto clear7d iniziale.
La semantica UI esatta e una correzione persistente devono ancora essere provate.
La sola coppia osservata non giustifica modifiche arbitrarie al save o al core.

Root ha riverificato tutti4file raw seed contro `.local/completeSaves` e hash
originali: identici. L’importer copia i file e crea metadati archivio, non modifica
opzioni. `.local/cpp-option-stages/save-source-comparison.json`.

Prove parallele attive: Sol diagnostica Off→On e setter+7e; root in
`.local/cpp-mode-validation/` usa core37 e una copia privata dello snapshot Harvest
accettata. MenuCPPButtons mostravaType4; LEFT restaType4, RIGHT mostraType1,
LEFT tornaType4, A e B×2 escono. Nessun Off→On nella branca root. Partenza Harvest
verificata visivamente; replay camp→ricompense15.710frame in corso. Conservato
`departure.mh4ustate`. Serve verificare finequest, nuova camera, ordinarysave e
freshContinue prima di dichiarare risolto. Core e save utente invariati.

## Caccia riuscita confermata dall’utente — 2026-09-13

L’utente riferisce: «ho fatto una caccia ed è andato tutto liscio».
Registrare come riscontro manuale positivo di una caccia reale. Nome missione,
mostro, durata, impostazioni grafiche e salvataggio successivo non specificati.
Questa evidenza si aggiunge alla Harvest Tour automatizzata con salvataggio e
Continue verificati; non è un benchmark né prova di tutte le missioni.
L’ottimizzazione dello scambio BGRA è ancora in verifica separata: non attribuire
questa caccia al nuovo codice non ancora installato.

## Gameplay su copie isolate — 2026-09-13

Ripresa dopo la domanda sui tempi del port. Nessuna modifica al codice/build/core
in questa tranche; core corretto SHA `37f9a9230eb1efe0b6218fb58a0218f6a170f02d302af727d419aefac37816b4`.
Processo utente build PID 11452 rilevato all'inizio: nessun input OS, riavvio o
chiusura. Test CLI headless finiti, a 1× New 3DS, senza audio/temporale/texture
esterne. `pollInput()` ritorna subito in headless: non legge il controller fisico.

Root possiede `.local/quest-corrected-20260913/`, creata da snapshot del core
corretto (mai vecchi snapshot con percorsi assoluti). Prova Native avanzata:
cappello recuperato, corda/sentina/ponte; munizione raccolta e trasportata anche
attraverso load; sparo catturato in `cannon-shot.png`; secondo colpo con reazione
esplicita del Carovaniere in `second-shot.png`; cinematica del mostro che scavalca
la nave, spiegazione telecamera, secondo recupero corda/sentina/ponte.
**Tutorial non completato**, fase cannone sul lato opposto/gong ancora aperta.
Numerosi tentativi di navigazione e cadute conservati: non è un replay continuo
riuscito e non prova stabilità realtime o combattimento completo.

Report root `.local/quest-corrected-20260913/progress-report.json` con hash e
limiti. Runner locale `run.py NAME FRAMES [LOAD_SLOT=9]`, input in NAME-input.json,
load a frame 120 e save finale slot9; snapshot distinti in snapshots/NAME.mh4ustate.
Ultimo slot9 `gong-steady`: sulla corda dopo una caduta. Per ripartire meglio:
`second-shot.mh4ustate` (prima dello scavalcamento) oppure
`target-explanation.mh4ustate` (ponte dopo spiegazione camera), copiati in slot8
solo dentro questa stessa cartella isolata. Il doppio L è documentato nel manuale
Capcom pagina 26 per Target Cam, ma osservare l'inquadratura prima di concatenare
movimenti. Tenere R non ha evitato tutte le cadute: non attribuire automaticamente
le difficoltà di navigazione a un bug del runtime.

Sol `sol_advanced_save_validation` possiede solo
`.local/advanced-save-validation-20260913/`: dal salvataggio fornito dall'utente
Sora ha accettato Harvest Tour: Volcanic Hollow (2★ Low rank), caricato il campo
base, atteso la consegna del Paw Pass Ticket e consegnato 1 ticket. L'agente ha
ispezionato **QUEST COMPLETE**, ricompense e ritorno a Val Habar. Gate di
salvataggio ordinario **passato**: user1 e system cambiati, user2/user3 identici;
processo nuovo da 2.100 frame senza load mostra Sora 1488:26 (prima 1488:16),
secondo processo nuovo da 6.000 frame senza load torna a Val Habar. Root ha
ispezionato catture e verificato hash finali + contatori loads/saves=0 nei due
report raw. Non è prova di combattimento. Report definitivo
`.local/advanced-save-validation-20260913/completion-report.json`; snapshot di
QUEST COMPLETE in slot3 (SHA `922f0453b61bb1fb1c027e21b56f733b6e642961330719e35d77b4a85a48ae4`).
Il processo utente 11452 non era più presente al controllo finale dell'agente;
nessun segnale o controllo gli è stato inviato.

Ottimizzazione in verifica con Sol `sol_frame_transfer_review`: eliminata una
copia BGRA completa bridge→frontend tramite scambio dei vector; fence Vulkan e
attesa Metal restano necessarie. Agent possiede src/main.mm e src/vulkan_bridge.*,
build isolata `.local/frame-transfer-build`; root possiede
`.local/frame-transfer-validation/` per A/B. Baseline vecchio binario conservata,
scena second-shot caricata in stato corretto isolato, 1.200 frame a 1× e 4×.
Build isolata completata, 16/16 CTest passati. Smoke reale con 1→4→1 e
MetalFX temporale: 214 frame temporali, zero rifiuti di allineamento. A/B di
1.200 frame a 1× e 4× concluso: catture PPM identiche byte per byte prima/dopo.
Tempi headless singoli prima/dopo: 7,075/7,386 s a 1×; 16,922/17,397 s a 4×.
Non dimostrano miglioramento di velocità; è eliminazione di una copia CPU, con
piccola variazione sfavorevole non isolata da rumore/carico utente. Questa era la variante intermedia copy-only: il checkpoint più recente in cima
riporta la versione finale con passaggio alpha eliminato e frontend installato.
La regressione Circle Pad Pro resta separata e aperta.

## Isolamento dei savestate corretti — 2026-09-13

Ripresa automatica del goal: ispezionato codice attuale, comprese le modifiche
non committate delle altre sessioni. Il gioco build era già attivo (PID 622);
nessun input OS inviato, nessun riavvio o chiusura della sessione utente.

Scoperto un bug reale durante il replay del tutorial su una copia dello stato:
IOFile rimappava i percorsi, ma nove campi di mount/factory degli archivi
savedata/extdata/SDMC/NAND erano stringhe assolute. Dopo il load in un’altra
cartella, aperture successive potevano scrivere nella cartella originale.
Lo snapshot reale conservava 15 riferimenti al vecchio stato di test.
Non dichiarare isolate le vecchie prove di snapshot trasferiti tra state-dir
sulla sola base del parametro CLI. Entrambe le cartelle coinvolte erano di test;
non sono stati caricati snapshot dei salvataggi canonici dell’utente.

Correzione Sol in `patches/azahar-savestate-relative-paths.patch`: riusa
`FileUtil::Path::make` per nove campi in sette header, senza nuovi backend.
I builder applicano già tutte le patch azahar-*.patch. Applicazione ripetuta
verificata; header delle chiavi escluso, built-in keys OFF.
Regressione `relocated-savestate-paths` usa il vero SaveDataArchive, Boost,
OpenFile e Write: prima scriveva nella sorgente e falliva; dopo scrive solo
nella destinazione e passa. Tutti i **16 CTest passati**.

Core corretto: `37f9a9230eb1efe0b6218fb58a0218f6a170f02d302af727d419aefac37816b4`.
Replay nuovo di 7.400 frame da savedata ordinario privato; snapshot creato
senza riutilizzare quello difettoso. Dopo copia e caricamento in un processo
nuovo, 600 frame completati; scena nave ispezionata, sorgente sdmc/nand/sysdata
invariata. Entrambi gli snapshot contengono 15 placeholder e zero percorsi
assoluti delle due cartelle. È verifica di rilocazione e gameplay iniziale,
non completamento di missione o benchmark.

Installato con sostituzione atomica del core e firma app verificata; tutti i
20 file canonici sdmc/nand invariati. Il processo di gioco già aperto continua
con il core precedente fino alla chiusura. I vecchi snapshot RAM sono rifiutati
dal controllo SHA del nuovo core; per recuperarli è conservata la coppia
app/core precedente in `.local/savestate-path-validation/previous/`.
Usare quel core esplicitamente e la cartella originale dello snapshot,
mai una copia trasferita con il vecchio core. I salvataggi ordinari restano
compatibili; caricare un vecchio snapshot e poi salvare nel gioco può comunque
sostituire i progressi ordinari con quelli della sessione ripristinata.

App installata verificata anche con 300 frame e un load dello snapshot spostato:
uscita 0, sorgente invariata, zero percorsi assoluti e 15 placeholder.

Prove: `.local/savestate-path-validation/report.json`, `ctest.log`,
`installation.json`, `bootstrap-report.json`, `relocated-report.json`.
Il vecchio replay `.local/quest-validation-20260913/` è stato sospeso alla
sequenza successiva al tutorial telecamera; conserva diagnosi e catture.
Prossimo passo: riprendere la progressione su snapshot generati dal core
corretto e verificare una missione e il suo salvataggio ordinario.

## Importazione salvataggi — 2026-09-12

Implementati Game → Import Game Save… e Open Save Backups…. Selezione di cartella
raw MH4U (`user1`–`user3` da 81.408 byte, `system` da 512) o singolo userN;
riconosciuta anche root Azahar col percorso EU canonico. Riepilogo dei file,
accodamento nella cartella privata `<state-dir>/save-import/pending`, attivazione
prima del core al prossimo avvio. Stage copia solo file selezionati e registra
SHA-256; applicazione rivalida e unisce gli ultimi dati live degli slot non
selezionati, crea backup completo sotto save-import/backups, poi attiva mediante
rename swap atomico (rename per stato nuovo). Metadati Azahar corretti anche su
stato fresco e archivio corrente contenente solo system. Errori di sync/rename
bloccano l’avvio; cleanup pending controllato prima di permettere nuovi progressi.
Lock non bloccante sullo stato per evitare due runtime contemporanei sulla stessa
cartella. Link simbolici/componenti intermedi rifiutati. Nessuna modifica al core.

Importa solo savedata: niente extdata, ZIP, immagini SD cifrate o savestate.
Validazione strutturale di nomi/dimensioni; MH4U valida il contenuto del salvataggio.
Gli snapshot RAM esistenti conservano la vecchia sessione: dopo import usare Continue.
Il backup si può reimportare selezionando la sua cartella data/00000001.
CLI --import-save PATH --state-dir DIR accoda ed esce senza avviare il gioco;
--save-import-preview --state-dir DIR apre solo il selettore; --save-import-self-test
usa dati sintetici in .local. 15/15 CTest passati incluse input/device/backup,
integrità pending, lock, symlink e preservazione di slot aggiornati dopo lo stage.

L’utente ha fornito completeSaves: quattro file, 244.736 byte. Cartella spostata
intatta in `.local/completeSaves/` per rispettare i confini degli artefatti; SHA
in `.local/save-import-validation/source.json`. Import reale su copia Native:
stage lascia live invariato, attivazione copia tutti i file byte per byte e backup
identico al precedente savedata. Replay finito fino a Character Select riconosce
Sora, Kairi e Andrew (cattura characters.png); non è prova di caccia o di tutti i
contenuti dei salvataggi. Dati canonici dell’app non importati né sovrascritti.

UI: selettore nativo e percorso completeSaves osservati, due anteprime isolate
hanno accodato i quattro file ed emesso game_loaded=false. La revisione/conferma
non è stata catturata visivamente: CUA ha segnalato cambiamenti utente/uscita.
Seconda prova con bundle ID distinto local.mh4u.importcheck per non agganciare
altre istanze. È comparsa una sessione normale del bundle build (PID 36023, senza
argomenti, stato sviluppo .local/state): non inviare input né chiuderla come test.
Controllare processi prima di agire. Prove in `.local/save-import-validation/`.

Installazione completata, firma valida e tutte le 30 sezioni Mach-O corrispondenti
alla build. Core invariato rispetto ai savestate. App installata su import fresco
da UI: 600 frame, uscita 0, quattro file finali identici alla sorgente. Tutti i 20
file sdmc/nand canonici e la sorgente completeSaves invariati. Report report.json.


## Savestate — 2026-09-12

Implementati nel frontend: Game → Save State / Load State, tre slot UI;
⌘S/⌘L per slot 1. Usabili durante pausa manuale, che resta attiva dopo il load.
Snapshot in `<state-dir>/savestates/slotN.mh4ustate`, app normale nella cartella
privata Application Support. Serializzazione libretro già presente nel core;
contenitore limitato a 1 GiB con SHA core/config/payload, controllo dimensioni,
scrittura temporanea + fsync + rename. File corrotti/incompatibili respinti prima
del core; fallimento del core al load termina la sessione perché potrebbe essere
stata ricostruita solo parzialmente. Reset input/audio/temporale/pacing al load.
I savestate **non ripristinano savedata/extdata su disco** e non sono compatibili
con core binari o profili CPU/renderer/Old-New/DSP differenti. Risoluzione e
opzioni temporali possono cambiare. Snapshot test circa 30 MiB.

Corretto un blocco reale: export privo di .git generava revisione UNKNOWN;
SaveStateBuffer scriveva revision zero e LoadStateBuffer lo rifiutava. Ora
prepare_source scrive GIT-COMMIT e GIT-TAG dal pin verificato, usando il percorso
archive già previsto da Azahar. Nessun recupero del blob escluso; built-in keys OFF.

14/14 CTest passati, incluso native-savestate con callback sintetici e test della
provenienza senza rete. Replay nave 7.400 frame, snapshot prima/dopo movimento;
load in processi nuovi riusciti e catture della scena ispezionate. Due load dello
stesso snapshot producono SHA cattura identico. Troncamento/checksum/profilo
errato respinti. Prova CUA: salvataggio slot 3 in pausa, load slot 1 con ⌘L,
pausa conservata, ripresa della scena, ⌘S/⌘L durante gioco, uscita pulita.
Load a 4× con temporale: 182 frame temporali, zero mismatch di allineamento;
scena statica, non prova di interpolazione generata o di caccia completa.

App aggiornata e firma verificata; 30 sezioni Mach-O uguali alla build, core privato
SHA `6fd1e7ba94f052e360d961c2875c15eb2e12c06c77f3de918b769e09c390276d`.
Load dell’app installata su copia isolata: 300 frame a 4×, un ripristino, uscita 0.
Tutti i 20 file canonici sdmc/nand invariati dopo le prove e l’installazione.
Prove e copie isolate in `.local/savestate-validation/`; non copiare questi
snapshot o savedata sui dati canonici. CLI repeatable --savestate-save FRAME:SLOT
(dopo frame) / --savestate-load FRAME:SLOT (prima frame), slot 1–9, richiedono
--state-dir esplicito e --frames finito. Frame numerati da zero.


## Estensione temporale 1×–4× — 2026-09-12

MetalFX temporale e generazione ottica ora preservano la risoluzione interna
selezionata: 1×, 2×, 3× o 4×. Il core usa ABI 2 e legge colore/depth dalle
superfici Vulkan alla scala effettiva, con crop tiled corretto e controllo di
allineamento nel frontend. Input 400s×240s; output 800×480 a 1×/2×,
1200×720 a 3× e 1600×960 a 4×. Movimento stimato su proxy 400×240 e riportato
alla scala scelta; colore e profondità restano a piena risoluzione. Cambio scala,
pausa e discontinuità azzerano la cronologia. Le opzioni non forzano più 1×.

13/13 CTest passati, inclusi motion/processor GPU a tutte le scale. Replay reale
con cambi 1→2→3→4: 172 frame temporali, 167 generati, zero mismatch di allineamento.
Finestra negli ultimi 60 frame a 4×: 57 generati presentati, 117 presentazioni totali;
uscita 0. Catture finali 1600×960 ispezionate. Due frame di fallback per cambio scala
attendono nuova depth. La prima prova aveva crop errato ed è stata respinta dal
controllo di allineamento; non è stata installata. Prove corrette in
`.local/temporal-scales-validation/diagnostic.json` e `final.json`.

La generazione resta **interpolazione ottica sperimentale**, non MetalFX frame
interpolation. Nel segmento visibile tutte le 60 iterazioni superano il budget
16,67ms: nessuna promessa di aumento FPS o qualità, nessuna validazione di caccia
con l'intero pack HD. La patch core è riproducibile, verificata su baseline fissata;
`ENABLE_BUILTIN_KEYBLOB=OFF`. Salvataggi di prova isolati. Le nuove modifiche
savestate dell'altra conversazione sono state preservate; l'utente ha coordinato
il rilascio di main.mm/CMake/installazione durante questa integrazione.

**Installazione finale completata:** app firmata valida, tutte le 30 sezioni Mach-O
corrispondono alla build, core privato SHA-256
`1b896ef3fce97c493ba96b97374906ee8b839c5c24462932b3d9318b0e531bea`.
Il core finale richiede indirizzi base, dimensioni, formati e rettangoli completi
esatti per colore e depth. Replay finale `guarded.json` sull'eseguibile installato
con core validato: boot diretto 4×, cambi 4→1→2→3→4, 172 temporali/167 generati,
57 presentati a 4×, uscita 0, zero mismatch. Depth normalizzata non costante a tutte
le scale; a 4× variazioni dentro i blocchi nativi per 1.061.526 pixel nel primo
campione valido. 13/13 CTest sulla build finale passati; 14 file di salvataggio
canonici invariati. Report `.local/temporal-scales-validation/report.json`.
Nessuna modifica intenzionale alle preferenze del pack/profilo utente; CLI di prova
su stato isolato. Pannello Graphics non verificato manualmente in questa estensione.

## Integrazione temporale iniziale (checkpoint 1×) — 2026-09-12

Ripresa dopo rilascio main.mm/CMake da parte dell'agente texture. Frontend ora
consuma callback depth sincronizzate, confronta colore/presentato, usa movimento
Metal stimato + maschera di validità e MetalFX temporale 400×240→800×480. Le regioni
inaffidabili restano native; scene senza depth valida usano il percorso spaziale.
Opzioni Graphics persistenti, disattivate per default. Il temporale seleziona 1×;
la scelta di 2×–4× lo disabilita. CLI `--experimental-temporal`,
`--experimental-frame-generation`, `--no-temporal`, `--temporal-start FRAME`,
`--temporal-capture PREFIX`. Cambi CLI a risoluzioni >1 rifiutati con temporale.
`--window-start FRAME` richiede test finito e carica prima senza finestra.

Generazione implementata come **interpolazione ottica Metal sperimentale**, non
MetalFX frame interpolation. Due presentazioni ordinate midpoint→current per
intervallo core; input/core avanzano una sola volta, display inferiore separato.
Molte regioni mantengono current per evitare artefatti: nessuna promessa di maggiore
fluidità o prestazioni. Nel test tutte le iterazioni visibili superavano 16,67ms;
la generazione può rallentare la simulazione. Richiedono ancora sviluppo il jitter
3D, i vettori geometrici, proiezione camera e frame generation MetalFX vera.

12 CTest passati e sei combinazioni CLI invalide respinte. Replay headless 7.400
frame: 98 temporali/97 generati, zero presentazioni (correttamente), nessun
mismatch depth. Prova con finestra finale: 78 temporali, 77 generati e presentati,
157 presentazioni totali per 80 iterazioni visibili. Scoperto crash di teardown
MetalFX/MPS a uscita: corretta distruzione esplicita del processor in ~Core prima
del teardown statico; replay finale ripetuto e uscito 0, con gli stessi conteggi. Due prove precedenti in finestra
interrotte prima di entrare nella scena, non contano come convalida temporale.
Prove `.local/temporal-integration-validation/`; build isolata
`.local/temporal-integration-build/`. Salvataggi test separati da quelli canonici.

**Installazione completata:** app normale aggiornata e firma verificata; tutte le
sezioni Mach-O coincidono con la build, core privato aggiornato verificato SHA.
Boot dell'app installata 300 frame a 4× passato; handshake temporal_core_available
vero, modalità sperimentali off. 12/12 CTest finali passati; 14 salvataggi canonici
invariati. Report consolidato `.local/temporal-integration-validation/report.json`.
Pannello Graphics non verificato manualmente in questa integrazione.

## Texture pack HD — 2026-09-12

Richiesta utente: implementare caricamento pack dal post Reddit MH4U HD v3.0;
successivamente ha chiesto esplicitamente di scaricare/estrarre il pack per lui.
Questa autorizzazione riguarda soltanto il texture pack EU e i suoi aggiornamenti,
non ROM, update del gioco, chiavi, firmware o altri asset.

Implementati **Settings → Textures…**, importazione cartella estratta, checkbox
custom textures e profilo Old/New 3DS persistente. Importazione in staging privato,
attivazione al successivo avvio; PNG/DDS/KTX e pack.json ricorsivi, APFS clone con
fallback copia, controlli regione/symlink/config. Nessuna modifica al core:
`citra_custom_textures` e `citra_is_new_3ds`, caricamento asincrono su richiesta.
CLI: `--texture-pack DIR`, `--custom-textures` / `--no-custom-textures`,
`--old-3ds` / `--new-3ds`, `--textures-preview`, `--texture-pack-self-test`.
`--dump-textures` richiede `--state-dir` esplicito e `--frames` finito.

11 CTest passati, inclusi import/input/device/presentazione e il probe temporale
aggiunto da un altro lavoro concorrente. Prova reale Vulkan A/B: 600 frame ciascuna,
9 texture sintetiche a dimensioni doppie, tutte caricate nei log; cattura con
46.996 pixel magenta e 46.846 ciano contro zero nel baseline. Prove in
`.local/texture-validation/report.json`, `ctest.log`. È sostituzione realmente
renderizzata durante il boot, non validazione di caccia o dell'intero pack.
CUA: pannello leggibile e importazione di 10 file riuscita nella sola
`.local/texture-validation/ui-state`, lasciati in `.pending`; anteprima terminata.
I 14 file canonici savedata/extdata sono censiti in `saves-before.json`.

Download EU base e rollup v3.01–3.03 in `.local/texture-download/`:
https://pastebin.com/45Pu5HQP e https://pastebin.com/89XN1xCX.
La guida richiede Old 3DS per i mostri e update 1.1 per i font. Non scaricare
l'update del gioco.

**Completato:** base EU + rollup 3.01–3.03 scaricati, archivi estratti senza errori,
vecchia UI rimossa dalla copia assemblata prima dell'overlay, come da autore.
Cartella pronta `.local/texture-download/assembled/0004000000126100`, provenienza
e SHA archivi in `.local/texture-download/manifest.json`. Importati e confrontati
SHA-256 tutti i **12.004 file / 11.920.428.906 byte** nella cartella privata
`~/Library/Application Support/MH4U Runtime/.local/state/Azahar/load/textures/.0004000000126100.pending`.
Si attiva automaticamente al prossimo avvio normale. Preferenze verificate:
CustomTexturesEnabled=1, UseOld3DSProfile=1, InternalResolutionFactor=4.
Anteprima chiusa, nessun gioco avviato sullo stato canonico. Tutti i 14 salvataggi
canonici invariati; prove in `.local/texture-validation/pack-installation.json`
e `installed-pack-files.json`.

Prova pack reale nell'app installata: **1.500 frame Vulkan a 4× / Old 3DS**,
5 richieste di texture sostitutive caricate; cattura mostra il prompt iniziale
Circle Pad Pro. È verifica di boot/interfaccia, non di caccia o copertura completa.
Log pack: 58 duplicati di materiale e 30 nomi file invalidi ignorati dal core,
contenuti già presenti nel pack; nessun ritocco automatico degli asset.
Report `.local/texture-validation/real-pack-report.json`, `real-pack.png`,
`pack-loader-notes.json`. App finale firmata valida, tutte le 30 sezioni Mach-O
corrispondenti alla build (`installation-check.json`). Ultimi 11 CTest passati.

Un'altra sessione stava integrando il temporale in main.mm/CMakeLists.txt;
l'utente le ha fatto sospendere quei file, poi la build condivisa è stata
ricompilata, verificata e installata. Quel lavoro resta parziale e fuori dallo
scope texture. **I file condivisi sono ora liberi per la ripresa dell'altro agente.**

## Stato della sessione

**Ripresa esplicitamente dall'utente il 2026-09-12.** La precedente pausa risale al
2026-09-11, ore 17:24 circa Europe/Rome. Il runtime era stato chiuso con Command-Q.
Alla ripresa non risultavano runtime, riferimenti o build del progetto attivi.
La verifica Sol delle Preferenze del riferimento è passata. La prova privata ha
recuperato il cappello, risalito corda e sentina ed è tornata sul ponte. L'utente ha
poi chiesto di giocare personalmente e ha spostato il lavoro su controller e schermi.
Non inviare input di gioco mentre l'utente sta giocando; osservare e guidare.

## Temporale e generazione frame — lavoro in corso, 2026-09-12

L'utente ha chiesto di proseguire con entrambi. Aggiunto `temporal-probe` CMake/CTest:
**esecuzione GPU reale** di MetalFX temporal scaler e frame interpolator su M2 Pro,
scena sintetica con depth prospettica e movimento coerenti. Verifica posizione,
reset senza scia residua e centro interpolato distante da entrambi i frame sorgente.
La prima versione dell'asserzione era troppo permissiva; corretta per rifiutare
copie del frame corrente. Storia continua di 29 coppie: ultime tre passano il
criterio di midpoint ±4 pixel e distanza dagli endpoint ≥4 pixel. I primi output
possono ripetere il frame corrente. **Non è prova di frame generation nel gioco.**

Aggiunta patch riproducibile `patches/azahar-temporal-depth-probe.patch`, opt-in
`MH4U_TEMPORAL_PROBE=1`. Traccia draw/transfer/display e provenienza per intervalli:
il gioco trasferisce da 0x180f0800 dentro il render target RGBA8 0x180d4800,
256×512, crop offset 114688 byte / 112 righe. Depth D24S8 a 0x183fd400.
Campionamento one-shot prima del riuso della depth tra schermi, con flush CPU:
`MH4U_TEMPORAL_DEPTH_SAMPLE_FRAME=7399`, `MH4U_TEMPORAL_DEPTH_DUMP=` directory
assoluta esistente sotto `.local/`. Dump colore/depth tiled e metadata privati.
Decodifica Morton8×8, crop e rotazione mostrano cacciatore/ponte allineati;
39.204 valori depth distinti nella prima cattura. Questo dimostra depth reale
nella scena, non validità universale su HUD, postprocess e tutti i draw.

Core sperimentale linkato separatamente in `.local/temporal-validation/` usando
il target statico CMake `video_core` e il comando link generato da Ninja con output
separato. Dylib normale invariato; non installata la variante sperimentale. Replay
finito 7.400 frame con `tests/sandship-input.json` e copia privata Native, senza
input alla sessione dell'utente. Prove, log, dump e script di analisi sono sotto
`.local/temporal-validation/`; nessun asset proprietario aggiunto al repository.

Verifica finale: **11/11 CTest passati**, replay Vulkan 7.400 frame completato;
core normale invariato. Report consolidato `.local/temporal-validation/report.json`.
Tutti i 14 file savedata/extdata canonici invariati.

**Da implementare:** interfaccia per depth sincronizzata verso frontend, vettori
current→previous affidabili dal renderer, convenzioni/proiezione camera, trattamento
HUD, reset cronologia e pacing dei frame interpolati. La UI resta correttamente
disabilitata: queste funzionalità non sono ancora disponibili durante MH4U.
Non sostituire i dati mancanti con depth/motion finti. Un'eventuale stima ottica
va dichiarata e validata come approssimazione. Nessun ABI generico anticipato.

## Risoluzione interna e qualità — 2026-09-12

L'utente ha scelto esplicitamente **prima risoluzione interna e qualità** rispetto
al lavoro su temporale/frame generation. Implementata e installata la scelta
persistente **1×–4×** in Settings → Graphics, da 400×240 a 1600×960 per il display
superiore. Si applica al primo frame dopo la chiusura del pannello/ripresa, tramite
GET_VARIABLE_UPDATE → ParseCoreOptions/ApplySettings/UpdateLayout del core pinned.
Nessuna modifica al core necessaria. Il bridge accetta solo il canvas 400×480 a
scale intere 1–4; staging limitato a 12.288.000 byte. Crop e touch proporzionali.
MetalFX attivo solo quando serve ingrandire; lo stato nel pannello viene aggiornato.
Le risorse Metal 4 sono ora predisposte anche se MetalFX parte disattivato.

**Nove CTest passati**, compresi readback 2×/4×, input e audio. Boot Vulkan isolato
di 300 frame passato a ciascuna delle quattro scale. Prova di 600 frame nello
stesso processo: dimensioni reali 400×480 → 1600×1920 → 800×960 → 400×480 ai frame
0/150/300/450. Sei casi CLI invalidi rifiutati. Nuovi argomenti `--resolution 1..4`
e `--resolution-change FRAME:SCALE` (ripetibile, richiede `--frames`); non scrivono
preferenze. Test sintetici indipendenti dalle preferenze dell'utente.

CUA ha verificato visivamente il pannello: **4× — 1600×960**, **Active: Metal 4FX**,
temporale/frame generation disabilitati con spiegazione; nessun testo tagliato.
La prova isolata PID 13948 è terminata prima del limite e ha registrato un cambio
1×→4× al frame 574. Durante la verifica UI è comparsa una nuova sessione normale
PID 14080, senza argomenti: non confonderla con lo stato di test. Sono stati soltanto
aperti/letti/chiusi i menu; nessun input di gioco inviato. Lasciate la sessione
normale aperta e la preferenza 4× corrente. Ricontrollare i processi prima di agire.

Codice installato confrontato con la build (esclusa firma aggiornata) e firma valida.
Tutti i 14 file savedata/extdata canonici invariati dopo prove, installazione e UI.
Prove in `.local/resolution-validation/report.json`, `ctest.out`, `boot-*x.out`,
`live.out`, `gui.out`. Sono verifiche di boot/rendering e interfaccia, non benchmark
di caccia né accettazione completa del gameplay a 4×. Temporale e generazione frame
richiedono ancora depth/motion coerenti con il frame finale e modifiche al renderer.

## Menu grafica, pausa e audio — 2026-09-12

Implementati e installati **Settings → Graphics…**, **Settings → Audio…** e
**Game → Pause Game / Resume Game** (Cmd+P). MetalFX spaziale attivabile a runtime;
volume e mute applicati ad AudioQueue. Preferenze persistenti. Upscaling temporale
e generazione frame visibili ma disabilitati: mancano i dati motion/depth nel
percorso corrente, non sono funzionalità implementate. Risoluzione interna 1×.

Le finestre delle impostazioni sospendono core e audio; la chiusura preserva una
pausa manuale. Ripresa con input azzerati, release gate controller e pacing
reiniziato. La pausa mantiene la sessione in RAM, non crea un savestate su disco.

Sette CTest passati: nuovo test AudioQueue reale con silenzio, volume/mute,
callback fermi in pausa e ripartiti al resume; test MetalFX off/on e readback
dei tre percorsi. Probe GPU e boot isolato Vulkan di 300 frame passati.
Corrette due condizioni dei test (campione sul bordo del cursore e verifica
toggle quando MetalFX parte già disattivato). Revisione indipendente Sol senza
difetti materiali. Non eseguita una prova manuale dei pannelli durante il gioco.
Prove in `.local/settings-validation/report.json`, `ctest.txt`, `smoke.json`.
App firmata verificata; codice installato corrispondente alla build. I 14 file
savedata/extdata canonici sono invariati prima/dopo prove e installazione.

La sessione utente PID 11089 risultava aperta su `.local/touchcursor-validation/state`;
non è stata chiusa né ha ricevuto input da questa attività. I nuovi menu richiedono
un nuovo avvio dell'app. `--settings-preview` apre il pannello grafico senza gioco
o salvataggi; è un'anteprima manuale, non un test automatico.

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
menu osservati. L'utente ha confermato esplicitamente che Cerchio avanza il gioco
e il clic sul touchpad mostra/nasconde lo schermo inferiore. Questa verifica fisica
è confermata dall'utente; non equivale a una prova di tutti i tasti rimappabili.

## Cursore touchpad e R3 — 2026-09-12

Richiesta successiva: usare il touchpad per muovere un cursore nel display inferiore
e R3 per confermare il tocco. Implementato e installato. Coordinate assolute;
il cursore resta fermo sollevando il dito, R3 tenuto consente trascinamenti. R3 è
riservato al touch mentre il riquadro è visibile; un precedente Toggle Lower=R3
viene interpretato come clic touchpad e normalizzato al salvataggio delle preferenze.
Mouse e controller condividono un solo touch 3DS, con priorità a R3 premuto/latched.

Cursore MSL bianco/nero sul solo overlay, dimensioni in punti anche su Retina.
Si usa GCControllerTouchpad.touchState quando disponibile; il fallback pubblico
DualSense/DualShock touchpadPrimary non espone contatto e ignora (0,0) per non
spostare il cursore al rilascio. Limite: contatto esattamente centrale ambiguo nel
fallback. Nessun HID privato, driver, permesso aggiunto o movimento del cursore OS.

Tutti i 6 CTest e boot finito 300 frame superati; test su coordinate, bordi,
rilascio R3, mouse, hide/focus/disconnect, readback centro e bordo del cursore.
Revisione indipendente Sol senza difetti materiali. Cursore visibile osservato
con CUA. Le prime due prove fisiche sono fallite: il cursore non si muoveva.
Diagnosi: il DualSense Bluetooth inviava report semplici 0x01 di 10 byte, privi
di touch; GameController restituiva valori fissi (-1,+1). La lettura pubblica
IOKit del feature report 0x09 abilita report completi 0x31 di 78 byte. Dopo questa
inizializzazione, osservati 1.755 callback continui e R3 corretto; l'utente conferma
«i valori cambiano» nella finestra diagnostica. Nessun contenuto identificativo del
feature report viene conservato o stampato.
Revisione finale Sol: nessun problema nel caso verificato con un solo DualSense.
Limite noto: con più DualSense Bluetooth, la scelta del primo dispositivo IOKit
non è associata al controller GameController selezionato; quel caso non è supportato
dalla verifica attuale e richiederà correggere la selezione prima di dichiararlo supportato.

La build installata inizializza automaticamente il DualSense Sony 054c:0ce6 Bluetooth
al cambio controller, poi continua a leggere il touch con GameController. Il log
del gioco riaperto conferma il successo dell'inizializzazione. Tutti i 6 CTest e
un nuovo boot finito di 300 frame sono passati anche con questa correzione.
**Verifica fisica nel gioco aggiornata: PASSATA.** L’utente ha risposto
«Funzionano entrambi» alla prova del cursore che segue il dito e della selezione
con R3. Questo conferma entrambi i comandi nel gioco, oltre alla diagnostica.
Prove: `.local/gamecontroller-probe-result.txt`,
`.local/touchcursor-validation/report.json`, `smoke-final.json`.

**Sessione interattiva aggiornata aperta senza timer né watchdog:** processo e comando
in `.local/touchcursor-validation/fixed-interactive-process.json`, log
`fixed-interactive.log`. La prima sessione (`interactive-process.json`,
`interactive.log`) era stata chiusa dall'utente prima della correzione.
Usa `.local/touchcursor-validation/state`, copia dello stato privato precedente;
non sovrascrive i salvataggi canonici dell'app. Controllare processi prima di
riaprire, non interrompere il gioco dell'utente e non inviare input di gioco.
L'ultima osservazione CUA mostrava Character Creation e il riquadro col cursore;
non è una prova di completamento tutorial o salvataggio progressi. La vecchia prova
`.local/controller-validation` con limite 36.000 frame è ormai conclusa.

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
salvataggio e ricaricamento dei progressi della missione, copertura completa dei
comandi del controller fisico, qualità
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
