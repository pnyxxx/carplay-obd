# TrackGauge : turbo, régime et température en direct (iPhone + CarPlay)

Projet de test pour la piste. On lit le moteur avec un adaptateur **Veepeak OBDCheck BLE+**, puis on affiche :

- **sur l'iPhone** (sur un support) : jauges plein écran **en temps réel**. Aiguille de turbo avec pic et consigne du calculateur, régime façon shift-light, températures d'eau et d'air, courbe de turbo des 20 dernières secondes ;
- **dans CarPlay** : une **Live Activity** sur le Dashboard (l'écran carte + infos), avec cadran de turbo, régime et température d'eau. Elle s'affiche aussi sur l'écran verrouillé et dans la Dynamic Island.

Véhicule de test : **BMW 320d E90**. L'analyse complète (options CarPlay, limites, sources) est dans [docs/ANALYSE.md](docs/ANALYSE.md).

> Usage sur circuit uniquement. Ne pas manipuler l'iPhone en roulant.

---

## Comment c'est construit

```
Veepeak BLE+ ──Bluetooth LE──▶ BLELink ──▶ OBDKit (ELM327 : init, détection, boucle rapide)
                                                 │
                                                 ▼
                                          TelemetryStore ──▶ jauges iPhone (temps réel)
                                                 │
                                                 └──▶ Live Activity ──▶ CarPlay / écran verrouillé
```

| Dossier | Contenu |
|---|---|
| `Packages/OBDKit/` | Protocole ELM327 / OBD-II en Swift pur : décodage CAN et K-line, trames ISO-TP, requêtes groupées, choix de la source turbo (PID 0x70 > 0x87 > 0x0B), simulateur de 320d. **Testé sous Linux.** |
| `App/` | App SwiftUI : Bluetooth (`BLELink`), logique (`TelemetryStore`), tableau de bord, réglages, diagnostic, raccourcis Siri. |
| `LiveActivity/` | Extension WidgetKit : Live Activity (écran verrouillé, Dynamic Island, **famille `small` pour CarPlay**). |
| `Shared/` | Code commun à l'app et à l'extension (données de la Live Activity, jauges). |
| `project.yml` | Description du projet Xcode (XcodeGen) : pas besoin de Mac pour le modifier. |
| `.github/workflows/build.yml` | Compilation sur un Mac de GitHub, publication de l'IPA. |

## Travailler depuis Ubuntu (sans Mac)

1. On modifie le code ici, sous Linux.
2. On teste le cœur OBD en local : `./scripts/test-obdkit.sh` (Docker, image `swift:6.2`).
3. `git push` : GitHub Actions compile l'app sur macOS 26 avec le dernier Xcode. L'IPA non signée est publiée dans la release **latest** : https://github.com/pnyxxx/carplay-obd/releases/tag/latest
4. On signe l'IPA et on l'installe sur l'iPhone avec un identifiant Apple **gratuit** (ci-dessous).

## Installer l'app sur l'iPhone (compte Apple gratuit)

### Une seule fois

1. Installer usbmuxd (déjà présent sur ton PC) : `sudo apt install usbmuxd`
2. Télécharger **iloader** pour Linux (`iloader-linux-amd64.deb` ou `.AppImage`) depuis la source officielle : https://github.com/nab138/iloader/releases, puis `sudo apt install ./iloader-linux-amd64.deb`
3. Sur l'iPhone, il faut un code de verrouillage. Brancher l'iPhone en USB et accepter « Faire confiance à cet ordinateur ».

### À chaque nouvelle version (et au moins tous les 7 jours)

1. `./scripts/telecharger-ipa.sh` : l'IPA arrive dans `~/Téléchargements/TrackGauge-unsigned.ipa`.
2. Ouvrir iloader, se connecter avec son identifiant Apple, choisir l'iPhone, puis **Import IPA** et sélectionner le fichier.
3. Première fois seulement, sur l'iPhone :
   - **Réglages > Confidentialité et sécurité > Mode développeur** : activer, puis redémarrer ;
   - **Réglages > Général > VPN et gestion de l'appareil** : faire confiance à ton identifiant Apple.

Avec un compte gratuit, l'app expire au bout de **7 jours** : il suffit de refaire l'étape 2.

**Si l'installation ou le lancement échoue** (iloader a des bugs ouverts sur iOS 27 en octobre 2026, voir l'analyse) :
- Mettre à jour iloader. Dans ses réglages, essayer avec et sans « utiliser le profil principal pour les extensions ».
- Sinon, installer **SideStore** via iloader et ouvrir l'IPA avec SideStore depuis l'iPhone.
- Solution sans bricolage : le compte développeur payant (99 €/an) avec TestFlight. Pas d'expiration à 7 jours ; je peux ajouter l'envoi automatique vers TestFlight au workflow.

## Utilisation

1. Brancher le Veepeak sur la prise OBD (sous le volant, à gauche) et **mettre le contact**. Ne pas l'appairer dans les réglages Bluetooth de l'iPhone.
2. Ouvrir TrackGauge, appuyer sur **Connecter**. L'app trouve l'adaptateur, le mémorise, détecte le protocole et les capteurs, puis lit en continu. Le bouton liste permet de choisir l'adaptateur à la main.
3. Autoriser le Bluetooth, la localisation (pour rester actif en arrière-plan) et les Live Activities.
4. Dans CarPlay : la Live Activity apparaît **sur le Dashboard** (écran partagé). Bouton CarPlay de l'app pour l'afficher ou la retirer.
   - Si rien n'apparaît : **Réglages > TrackGauge > Live Activities** activé ; **Réglages > Général > CarPlay > [ta voiture]** pour les options d'affichage.
5. **Démo** : sans voiture, une 320d simulée enchaîne des accélérations. Toute la chaîne (OBD, jauges, Live Activity, CarPlay) est exercée.

### Démarrage automatique en montant dans la voiture

App **Raccourcis > Automatisation > + > CarPlay > Se connecte > Exécuter immédiatement**, action **« Démarrer la télémétrie »** (TrackGauge). Même chose avec « Se déconnecte » pour « Arrêter la télémétrie ».

### Diagnostic

**Réglages > Diagnostic** affiche le protocole détecté, les PID supportés par la voiture, la source de turbo, les optimisations actives, le débit (mesures/s, temps de réponse) et le nombre de mises à jour CarPlay par minute. **Partager le journal** envoie l'échange complet avec l'adaptateur : c'est ce qu'il faut me transmettre en cas de souci.

## À tester en premier sur la 320d (moteur à l'arrêt, contact mis, puis moteur au ralenti)

- [ ] Connexion au Veepeak, puis le protocole affiché (CAN = E90 de 2007 et après, K-line = plus ancienne)
- [ ] Régime au ralenti (~800 tr/min) et en donnant des coups d'accélérateur à l'arrêt
- [ ] Température d'eau qui monte
- [ ] Source turbo détectée (0x70, 0x87 ou 0x0B) et valeur ≈ 0,0 bar au ralenti
- [ ] Débit « Turbo + régime / s » dans Diagnostic
- [ ] Live Activity visible dans CarPlay, et mises à jour par minute réellement obtenues
- [ ] Écran verrouillé 10 minutes : la lecture continue-t-elle ?
