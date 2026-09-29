# Corrections après les diagnostics de 5923e441fa70

Le journal fourni montre trois échecs identiques de métadonnées Spotify (`items`,
`tracks`, document de playlist : HTTP 404), avant tout appel YouTube. Il ne permet
pas de distinguer une restriction de l’API d’un problème d’identifiant/session.
`annotations_matched: 0` compte les résultats pour une sélection ; ce n’est pas un
code HTTP et cela ne signifie pas que Genius échoue sur toutes les chansons.

## Lecture native des playlists

`PWNativePlaylist.swift` lit uniquement le modèle de la playlist affichée, au clic.
Les champs ont été vérifiés dans les métadonnées Swift du binaire Spotify 9.1.78
(917802214) de l’artefact du run 36600291269 :

- `FTPViewModelImplementation.entityModel` : `PLPlaylistEntityModel`.
- `entityURL`, `metadata` (`ListMetadata`), `tracks` (`PLPlaylistTracksModel`).
- `ListMetadata.isLoaded`, `totalLength`.
- `PLPlaylistTracksModel.items`, `loadedItemCount`, `unfilteredLength`, `unrangedLength`.
- `PlaylistEntityItem.loaded(ListItem)` / `.unloaded(...)`.
- `ListItem.uri`, `isRecommendation`, `metadata` ; métadonnées `name`, `artists`,
  `duration` et `ListItem.Artist.name`.

La réflexion Swift évite les offsets mémoire et les sélecteurs supposés. L’URI
et tous les compteurs doivent correspondre. Une liste partielle, filtrée ou avec
des recommandations injectées n’est jamais mise en file comme liste complète.
L’API Web reste le secours si la lecture native est indisponible/incomplète.
Les grandes playlists chargées par fenêtres peuvent donc encore échouer : cette
correction ne fournit pas un chargeur natif paginé. Les nouveaux événements
`playlist_native_loaded`, `playlist_native_incomplete` et
`playlist_native_unavailable` permettent de distinguer ces cas sans journaliser
les titres, identifiants ou jetons.

## Genius et dossier

La correspondance accepte une annotation couvrant une sous-phrase ou plusieurs
lignes, normalise les apostrophes et conserve des limites de mots. Jusqu’à trois
fiches de titre/artiste identiques sont essayées si aucune annotation ne correspond.
La pagination continue jusqu’à une page vide (20 pages maximum), avec protection
contre les pages répétées. Les annotations déjà trouvées restent affichées si une
page suivante échoue. Aucune garantie de couverture de toutes les annotations.

Le sélecteur de dossier est présenté en plein écran. L’écriture coordonnée d’un
fichier vide temporaire vérifie l’accès avant de mémoriser le dossier ; un retour
`false` de `startAccessingSecurityScopedResource` ne rejette plus à lui seul les
URLs du conteneur de l’app. La sélection, l’annulation et l’échec sont journalisés.

## Vérification sur iPhone encore nécessaire

1. Choisir un dossier local, puis un dossier iCloud et vérifier la confirmation.
2. Télécharger une petite playlist sans filtre : attendre `playlist_native_loaded`
   puis les étapes YouTube. Vérifier séparément une grande playlist et Titres likés.
3. Refaire un appui long qui fonctionnait déjà, puis celui dont l’annotation porte
   sur une partie seulement de la ligne. Comparer avec la page Genius.

Les tests de règles et la compilation iOS ne remplacent pas ces essais sur appareil.
