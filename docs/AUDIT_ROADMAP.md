# Apollo audit roadmap

Estado: auditoría estática sobre `main` (build 923). Cada fase se cierra con
tests de CI y una IPA; no se marca como hecha sin probarla en dispositivo.

## P0 — corrección / release

- [x] CSV picker: aceptar CSV con UTI genérico (build 923).
- [x] Progreso/“reproducido” de podcasts usando el id de catálogo (build 924).
- [x] Saneado del nombre de archivo de descargas (título y videoId con token base64url).
- [x] Alinear `IPHONEOS_DEPLOYMENT_TARGET` 26.2 con `minOSVersion`/README (metadata a 26.2).
- [x] Evitar que `SearchService` cancele búsquedas de otros consumidores.
- [x] IDs Spotify en todas las rutas de cola (quitar actual, autoplay, surprise; ahora pasan por `playCurrentSong`).
- [~] JioSaavn: caché de stream antes y presupuesto de 1.5 s; el resto pasa a YouTube y se mejora en background.

## P1 — playback y datos

- [x] Carrera RSS/YouTube: primer carrier gana sin esperar al perdedor (race no estructurada).
- [x] `startRadio` no pisa una cola si cambia la generación.
- [x] `disableShuffle` restaura por catalogID o videoId.
- [ ] Evitar doble conteo en upgrade en caliente / Apolo→mpv.
- [x] `SponsorBlockIntegration`: resetea `skipped` al repetir o rebobinar.
- [x] Podcast: `bestEpisode` con tolerancia 120 s y desempate por duración.
- [ ] Descargas: `failedAddonKey` real, reintento y fallback.
- [ ] Addons: calidad en descarga directa, esquemas HTTPS, bloquear loopback/IP privadas y respuestas gigantes.

## P2 — catálogo y metadatos

- [x] Normalización Unicode (CJK/árabe/cirílico) sin colisiones.
- [~] Filtro explícito en Search/álbum/playlist/artista; falta Library local.
- [x] Compartir canciones/álbumes/artistas/podcasts usa open.spotify.com cuando el ID es Spotify.
- [ ] Playlist: parsear todas las formas de imagen y paginación completa.
- [ ] Artwork: portadas de playlist y fuentes sin imagen 1200 (mosaico/placeholder consistente).
- [ ] Podcast: bio/feed y artwork con una sola identidad de show.

## P3 — seguridad, ajustes y limpieza

- [ ] Secretos de addons en Keychain.
- [ ] Descargas/CSV: nombres y rutas seguras, sin traversal.
- [ ] `UIFileSharingEnabled`/document types revisados.
- [ ] Logs sin datos sensibles; eliminar ramas/viejos paths y código muerto.
- [ ] Tests de DownloadManager, MusicAddonClient, RSS y migraciones.

## Regla de cierre

1. Cambio pequeño y explicado.
2. `tree-sitter`, checks de CI y build.
3. Prueba en dispositivo del flujo afectado.
4. Si falla, se corrige antes de pasar al siguiente punto.
