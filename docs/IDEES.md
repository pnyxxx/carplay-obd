# Idées d'améliorations pour TrackData

⭐ = recommandé en priorité · 🟢 facile · 🟡 moyen · 🔴 gros chantier

## Piste et pilotage
- [ ] ⭐🟡 **Chrono au tour GPS** : ligne départ/arrivée posée d'un appui au passage, temps au tour, meilleur tour, **delta en direct** (+0,3 s) visible dans CarPlay. Le GPS de l'iPhone donne 1 point par seconde ; avec interpolation on vise environ 0,1 s de précision. Un GPS Bluetooth 10 Hz (type RaceBox) ferait mieux, en option.
- [ ] 🟡 Circuits mémorisés (ligne et secteurs), temps par secteur.
- [ ] 🟢 **Mesures de performance** : 0-100 km/h, 80-120 km/h, 400 m / 1000 m départ arrêté, lancées automatiquement au démarrage.
- [ ] ⭐🟢 **Shift-light** : écran qui flashe, bip et vibration au régime choisi.
- [ ] ⭐🟢 **Alertes** (bannière CarPlay via la Live Activity) :
  - eau trop chaude ;
  - moteur froid : « pas de pleine charge avant 70 °C » ;
  - tension batterie basse ;
  - turbo anormal (au-dessus de la consigne, ou nettement en dessous = fuite possible).

## Enregistrement et analyse
- [ ] ⭐🟡 **Enregistrer chaque session** : toutes les mesures + GPS, liste des sessions avec résumé (pics, températures max, nombre de tours).
- [ ] 🟡 **Graphiques après la session** : turbo, consigne, régime et vitesse par tour ; deux tours superposés pour comparer.
- [ ] 🟢 **Export CSV / GPX** (Excel, RaceChrono…) via le menu Partager.
- [ ] 🟡 Carte du circuit colorée selon le turbo ou la vitesse.

## Plus de données moteur (OBD standard)
- [ ] 🟢 Écart consigne / réel du turbo affiché en clair (si la voiture fournit le PID 0x70).
- [ ] 🟢 Autres mesures selon ce que ta 320d supporte : charge, pédale, débit d'air (MAF), pression du rail, température des gaz d'échappement, pression différentielle du FAP. La liste exacte est dans le journal de Diagnostic.
- [ ] 🟢 Consommation instantanée (si le PID 0x5E est supporté).
- [ ] 🟢 **Lire et effacer les codes défaut** (voyant moteur) après une journée de piste.

## Données BMW (au-delà de l'OBD standard)
- [ ] 🔴 **Protocole BMW du calculateur DDE (N47)** : température d'huile (absente de l'OBD standard, précieuse sur piste), température réelle des gaz, charge et régénération du FAP, couple, quantité injectée, température de boîte… Gros chantier : il faut retrouver les identifiants BMW de ton calculateur.

## Affichage et CarPlay
- [ ] 🟢 Choisir les valeurs de la Live Activity (ex. turbo + huile + delta chrono).
- [ ] 🟢 **Apple Watch** : la Live Activity s'affiche déjà dans la Smart Stack (même format que CarPlay) ; à vérifier si tu as une montre.
- [ ] 🟡 Widget CarPlay / écran d'accueil « dernière session ».
- [ ] 🟡 Écran iPhone personnalisable : choisir et réorganiser les tuiles, mode paysage « course » minimal.
- [ ] 🟢 Plusieurs véhicules (profils : échelles, zone rouge, adaptateur).

## Confort
- [ ] ⭐🟢 **Rappel d'expiration** : l'app lit sa propre date d'expiration (compte gratuit, 7 jours) et prévient « réinstalle avec iloader avant jeudi ».
- [ ] 🟢 Écran « Comment ça marche » au premier lancement.
- [ ] 🟡 Veille encore plus économe en batterie.

## Outils de développement
- [ ] 🟡 Émulateur d'adaptateur Bluetooth sous Linux, pour tester sans la voiture.
