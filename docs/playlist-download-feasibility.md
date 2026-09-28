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

## Implémentation locale du 28 septembre

Après élargissement de la recherche, **YouTubeKit** est retenu : Swift natif,
JavaScriptCore et URLSession, compatible avec iOS, sous licence MIT. Révision
`e5b7d0396ce12bf3444f0d209e8436c83373b7af`. Contrairement au portage complet de
SpotDL, il n’exige ni CPython ni un processus FFmpeg. Le fichier M4A est téléchargé
directement et vérifié par AVFoundation. Le mode `.local` est explicitement imposé ;
le service distant facultatif de YouTubeKit n’est jamais activé.

Reverie a servi de piste de recherche, sans reprise de son code. Son extracteur
active aussi un secours distant et son import HTML ne suffit pas à garantir une
playlist complète. L’import ici utilise l’API Spotify, avec pagination et contrôle
du total, via la session de l’application. Le bearer reste uniquement chez Spotify
et n’est ni journalisé, ni persisté dans la file, ni envoyé à YouTube. Un refus
401/403/429 reste une erreur visible ; aucun accès payant n’est forcé.

Deux choix locaux sont proposés : recherche de chansons **YouTube Music** ou
recherche **YouTube**, tous deux extraits par YouTubeKit. Le troisième choix rétablit
le téléchargement officiel Spotify. Ce ne sont pas des modes SpotDL/librespot.

La flèche native est réutilisée. Si Spotify ne crée aucun bouton sur le header
gratuit, un bouton de même fonction est ajouté dans sa rangée. Le redesign conserve
le bouton Ajouter et expose une quatrième commande pour télécharger. Le contexte
vient du modèle de la page affichée, jamais du morceau en lecture.

Sélecteurs vérifiés dans le Mach-O 9.1.78 fourni :
`SPTFreeTierPlaylistEncoreHeaderViewController.headerController` (`@16@0:8`) et
`FTPViewModelImplementation.playlistURL` / `playlistName` (`@16@0:8`). Le getter
`defaultHeaderViewModel` était déjà utilisé et vérifié par l’upstream. Tous les
appels vérifient à nouveau présence, nombre d’arguments et type de retour.

La file conserve ses métadonnées dans Application Support. Après redémarrage,
elle est en pause ; les fichiers terminés sont conservés et les entrées interrompues
peuvent repartir. Le dossier choisi utilise un bookmark, un accès security-scoped
et NSFileCoordinator. Les fichiers existants ne sont pas écrasés. Retirer une
playlist de la file ne supprime pas ses fichiers. La source et le dossier sont
figés pour chaque playlist ; pour changer une playlist déjà en file, la retirer
puis utiliser à nouveau sa flèche. Les erreurs ont un bouton de reprise.

### Limites de validation et d’usage

- Résultat réel du run `36382811432` : les deux modules compilent, 32 règles de
  téléchargement passent, mais la sonde réseau échoue avec `YouTubeKitError.extractError`.
  Le statut vert était dû à `continue-on-error`, désormais supprimé. Aucun HTTP 200
  ni téléchargement effectif n’a été validé dans ce run.
- Le run `36412391053` précise la cause : `LOGIN_REQUIRED`, raison
  `Sign in to confirm you’re not a bot`, aucune donnée de streaming. L’échec de la
  sonde est bien signalé. Elle devient manuelle, désactivée par défaut, pour ne pas
  répéter les demandes depuis ce runner bloqué. Elle s’arrête immédiatement si le
  fournisseur refuse la lecture, sans essayer un autre client ensuite.
- Sur iPhone, un échec d’extraction affiche une erreur compréhensible, inscrit
  `local_extraction_failed` dans les logs sans URL ni identifiant, puis suspend
  toute la file. Une reprise nécessite une action explicite de l’utilisateur.
- L’intégration reste expérimentale jusqu’au test sur l’iPhone cible. La compilation
  et les fixtures ne prouvent pas que YouTube autorisera un flux depuis son réseau.
- L’accès aux métadonnées dépend de Spotify : toutes les pages de playlists ont
  la commande, mais certaines playlists peuvent être refusées par l’API.
- Les résultats sont filtrés par titre, artiste et durée ; reprises, remixes et
  variantes non demandées sont refusés. Une absence de correspondance est affichée.
- Les fichiers exportés se lisent dans Fichiers ou une autre app. Ils ne remplissent
  pas le cache hors ligne du lecteur natif Spotify.
- Un seul morceau est traité à la fois. iOS peut suspendre la file en arrière-plan ;
  il faut la reprendre depuis sa page. Il n’y a pas de service d’arrière-plan garanti.
- Les doublons, épisodes et fichiers locaux sont comptés et ignorés. Limites :
  50 playlists, 10 000 entrées par playlist, 128 Mo par fichier audio reçu.
- Les journaux contiennent les étapes et codes d’erreur, sans titre ni URL audio.

## Sources officielles consultées

- https://github.com/spotDL/spotify-downloader
- https://github.com/spotDL/spotify-downloader/blob/master/pyproject.toml
- https://github.com/spotDL/spotify-downloader/blob/master/spotdl/utils/ffmpeg.py
- https://github.com/librespot-org/librespot/blob/dev/README.md
- https://github.com/librespot-org/librespot/wiki/Audio-Backends
- https://docs.python.org/3/using/ios.html
- https://docs.python.org/3/library/intro.html#mobile-platforms
- https://github.com/alexeichhorn/YouTubeKit
- https://github.com/alexeichhorn/YouTubeKit/issues/94
- https://github.com/mhadifilms/Reverie
- https://developer.spotify.com/documentation/web-api/reference/get-playlist-items
