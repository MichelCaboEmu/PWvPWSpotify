# Téléchargement de playlists : décision technique

Demande du 27 septembre 2026 : conserver le bouton Spotify, le rendre accessible
sur toutes les playlists, choisir le moteur et choisir un dossier dans Fichiers.
Contraintes confirmées : compte Spotify gratuit, fonctionnement entièrement sur
l’iPhone, sans ordinateur ni NAS.

## Résultat de l’examen des projets

- **librespot** est un client de lecture/Spotify Connect. Son README impose un
  compte Premium réel. Le backend `pipe` peut produire de l’audio pendant la
  lecture, mais ce n’est ni un gestionnaire de playlists téléchargées, ni le cache
  hors ligne du client Spotify. Le moteur est incompatible avec le compte gratuit
  demandé. Aucun jeton Premium ni contournement d’authentification n’est ajouté.
- **SpotDL 4.5.2**, tel que déclaré dans son `pyproject.toml` lors de l’examen,
  utilise Spotify pour les métadonnées et recherche des fichiers correspondants
  sur des fournisseurs comme YouTube. Python, yt-dlp et FFmpeg font partie de son
  environnement. `spotdl/utils/ffmpeg.py` appelle `subprocess.Popen` et
  `asyncio.create_subprocess_exec`. Ce fonctionnement ne peut pas être embarqué
  tel quel dans une application iOS standard. Python doit être embarqué comme
  bibliothèque ; la création de sous-processus n’est pas disponible.

Un serveur SpotDL serait une autre architecture, explicitement refusée par
l’utilisateur. Il ne sera donc pas ajouté comme dépendance cachée.

## Ce qu’exigerait un portage local

1. Embarquer CPython et les dépendances compatibles iOS, avec une chaîne de
   compilation et de signature reproductible. Vérifier notamment les modules
   binaires transitifs de Pydantic, RapidFuzz et yt-dlp.
2. Remplacer les appels au programme FFmpeg par une bibliothèque embarquée ou un
   export AVFoundation pour les formats effectivement pris en charge. Adapter les
   éventuels appels à un moteur JavaScript externe utilisés par l’extracteur.
3. Vérifier sur iPhone la recherche, l’extraction, les correspondances et la
   production d’un premier fichier complet. Une compilation ou une réponse de
   recherche ne suffisent pas à prouver le téléchargement.
4. Ajouter une file persistante, la progression, l’annulation et la reprise,
   en tenant compte de la suspension d’une application iOS en arrière-plan.
5. Choisir le dossier avec `UIDocumentPickerViewController` et conserver son
   autorisation via un bookmark. Utiliser les accès security-scoped et la
   coordination des fichiers ; ne pas supposer qu’un chemin arbitraire est accessible.
6. Connecter le moteur validé au bouton natif et à l’interface redessinée. Les
   fichiers exportés resteraient distincts des téléchargements officiels Spotify :
   leur lecture hors ligne dans Spotify nécessiterait une intégration supplémentaire.

## Points d’intégration trouvés dans le dépôt

- Le bouton natif est identifié par `DownloadButton.Granular.*`.
- `Redesigned/Kit/SGRDownload.m` lit son état et dessine son indicateur.
- `Redesigned/Playlist/PlaylistHeader.x`, fonction `showPlaylist`, préfère
  actuellement « Ajouter » au téléchargement sur une playlist appartenant à
  quelqu’un d’autre. Afficher les deux demande une adaptation du composant de
  boutons, sans supprimer la possibilité de suivre la playlist.
- `Native/Playlist/Playlist.x` contient aussi un réglage qui peut masquer le
  téléchargement. La visibilité doit rester cohérente avec les préférences.
- Les sélecteurs de métadonnées et actions des playlists devront être vérifiés
  dans le binaire 9.1.78. Ne pas déduire la playlist affichée du morceau en lecture.

## État

Recherche et points d’intégration documentés. Aucun moteur SpotDL/librespot iOS
fonctionnel, aucun faux sélecteur de source et aucun remplacement du téléchargement
natif ne sont livrés à ce stade. Le dossier d’export et le bouton seront raccordés
après validation du moteur local.

## Sources officielles consultées

- https://github.com/spotDL/spotify-downloader
- https://github.com/spotDL/spotify-downloader/blob/master/pyproject.toml
- https://github.com/spotDL/spotify-downloader/blob/master/spotdl/utils/ffmpeg.py
- https://github.com/librespot-org/librespot/blob/dev/README.md
- https://github.com/librespot-org/librespot/wiki/Audio-Backends
- https://docs.python.org/3/using/ios.html
- https://docs.python.org/3/library/intro.html#mobile-platforms
