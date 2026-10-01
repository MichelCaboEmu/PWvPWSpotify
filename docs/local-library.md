# Téléchargements et bibliothèque locale

La flèche relit la playlist visible à chaque demande. Une liste partielle reste un choix explicite. Les identifiants Spotify servent uniquement au catalogue, pas aux nouveaux noms de fichiers. Deux chansons de même nom utilisent un suffixe lisible `(2)` si nécessaire.

`PWDownloads/library.json` conserve les fichiers et l’appartenance aux playlists indépendamment de `queue.json`. Les anciennes entrées terminées de la file sont importées au lancement. Vider la file conserve ce catalogue et les fichiers. Un fichier supprimé, déplacé ou non disponible localement ne compte plus comme téléchargé. Les fichiers dont la file avait déjà été effacée avant cette version ne peuvent pas être associés automatiquement à leurs anciennes playlists.

La bibliothèque hors ligne présente uniquement les playlists avec au moins un fichier disponible, et indique le nombre local / le nombre référencé. Elle utilise AVPlayer dans l’application ; elle ne modifie pas le cache privé ou le réglage hors ligne de Spotify. Son ouverture automatique sans réseau est désactivable. Fermer le lecteur arrête sa lecture.

Le bouton Métadonnées interroge le catalogue iTunes avec titre/artiste, vérifie titre, artiste, version et durée, puis complète les tags M4A. Les recherches sont espacées. L’audio est exporté sans réencodage et sa durée vérifiée avant remplacement coordonné. Sans correspondance sûre, les informations connues sont conservées. Les anciens noms avec identifiants sont simplifiés pendant cette mise à jour. Les erreurs de métadonnées apparaissent dans Titres en erreur.

SoundCloud est une source facultative avec jeton OAuth personnel stocké dans le trousseau. Le secours s’applique uniquement aux recherches YouTube sans correspondance et aux flux 403/410 ; pas aux quotas, au consentement ou aux annulations. Il utilise `/tracks`, `downloadable` et le `download_url` renvoyé par l’API officielle. Les fichiers réservés à l’écoute sont ignorés. Les originaux autorisés sont convertis en M4A par iOS et leur durée contrôlée. Le jeton ne quitte pas api.soundcloud.com ; les redirections vers sndcdn.com n’en reçoivent aucun. Le jeton expire (généralement une heure) ; aucune clé d’une application tierce n’est intégrée, aucun renouvellement sans les identifiants API du propriétaire n’est simulé.

L’intégration aux lignes et menus utilise les classes et identifiants documentés par spoti.pw dans `PlaylistRows.x` et `SpeedPitchMenu.x`. Un titre est résolu dans le modèle vérifié de la playlist courante ; une ambiguïté laisse le menu inchangé. Aucun index de ligne n’est assimilé à un identifiant de morceau. La coche verte sur la pochette signale un fichier local disponible.

Sources :
- https://developers.soundcloud.com/docs/api/guide
- https://github.com/soundcloud/api/blob/master/openapi/api.yaml
- https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/iTuneSearchAPI/Searching.html
- https://developer.apple.com/documentation/avfoundation/avassetexportsession/metadata

Validation : tests Foundation du catalogue (persistance, migration, adhésion partielle/complète, identité globale, noms, filtrage des versions), tests existants audio/HTTP, prévalidation iOS et compilation fusion. Les interactions avec les vues privées, les dossiers tiers, les commandes du lecteur et SoundCloud authentifié doivent encore être testées sur l’iPhone.
