ASYNIOD.R4X
===========

ASYNIOD.R4X ist die Async-R4SYS-I/O- und Completion-Diagnose.

Projektstruktur seit 0.51.21:
- `build.zig` baut die Diagnose als eigenes SDK-Projekt.
- `build.zig.zon` bindet `r4os_sdk` als Paket.
- `module.R4MF` beschreibt Artefakt, Zielpfad, R4L-Imports und Contract.

Build:

    cd Code\System\Diagnostics\AsyncIoDiag
    ..\..\..\DevTools\Zig\zig.exe build

Ergebnis:

    Code\System\Diagnostics\AsyncIoDiag\zig-out\ASYNIOD.R4X

Contract:
- Build-Profil: `Zig/R4XStart`
- R4XStart-Entry: `asyniod_main`
- App-Klasse: `console`
- R4L-Imports: `R4SYS`
- Zielpfad im Image: `C:\R4OS\SOFTWARE\TERMINAL\DIAG\ASYNIOD.R4X`

Interner QEMU-Regressionsmodus seit 0.59.7:

    ASYNIOD /KILLWAIT <service-handle>

Der Modus submitet genau einen asynchronen `io_service_call` mit
`WAIT_FOREVER` ueber den vom Parent einmal geoeffneten Handle und blockiert
anschliessend in `io_wait(WAIT_FOREVER)`. Er oeffnet oder schliesst selbst
keinen Servicehandle. CLEANUPD synchronisiert den Kill ueber den R4DEV-
Taskzustand `blocked`/`completion` und die sichtbar belegte Stall-Queue.
