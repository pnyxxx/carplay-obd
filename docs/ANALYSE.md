# Analyse : comment afficher des données moteur dans CarPlay (novembre 2026)

Recherche faite avant de coder, à partir des documents officiels d'Apple (guide CarPlay d'octobre 2026, docs ActivityKit / WidgetKit, sessions WWDC25 et WWDC26) et de sources OBD. Les liens sont en bas de page.

## 1. Les façons d'afficher quelque chose dans la voiture

| Solution | Temps réel ? | Autorisation Apple | Verdict |
|---|---|---|---|
| **App iPhone** sur support (jauges plein écran) | Oui, 60 images/s, autant de mesures que l'OBD en donne | Aucune | ✅ Fait : c'est l'affichage « course » |
| **Live Activity dans CarPlay** (Dashboard, iOS 26+) | Quasi : iOS limite le rythme (budget non publié) | **Aucune** (« Your app does not need to be a CarPlay app ») | ✅ Fait : c'est l'affichage CarPlay |
| **Widget dans CarPlay** (iOS 26+, `systemSmall`) | Non : 40 à 70 rafraîchissements par jour (sauf quand l'app est au premier plan) | Aucune | 🔜 Plus tard, pour un résumé de session (pic de turbo, temp. max…) |
| **App CarPlay « driving task »** (listes, grilles…) | Interdit : règle n° 4, « no real-time engine data », 1 rafraîchissement / 10 s max | Droit CarPlay accordé par Apple | ❌ Apple refuserait ; inutilisable pour des jauges |
| **App CarPlay « navigation »** (dessin libre sur la carte) | Oui | Réservé aux vraies apps de navigation GPS | ❌ Impossible à obtenir |
| **App sur l'écran de la voiture** (boîtier AliExpress) | — | — | ❌ Boîtier Linux fermé, rien à installer (un boîtier Android l'aurait permis) |

### Pourquoi la Live Activity est la bonne porte d'entrée

- Le guide CarPlay d'Apple (13/10/2026) dit : *« Live Activities are supported with iOS 26 in CarPlay »* et *« Your app does not need to be a CarPlay app to support widgets and Live Activities in CarPlay »*. Pas de droit CarPlay à demander, ça marche aussi avec un compte Apple gratuit.
- Pour s'afficher dans CarPlay : *« support the small activity family »* (`.supplementalActivityFamilies([.small])`). C'est le même format que la Smart Stack de l'Apple Watch. On l'a fait, avec une mise en page dédiée : cadran de turbo, régime et barre shift-light, température d'eau, pic de turbo.
- Elle apparaît sur le **Dashboard CarPlay**, l'écran partagé avec la carte d'un côté et les cartes d'infos de l'autre. C'est exactement l'emplacement visé.
- Elle n'est pas interactive dans CarPlay (*« Buttons and toggles on Live Activities don't perform actions in CarPlay »*). Ça tombe bien : on n'en a pas besoin.
- Durée max : 8 h actives, puis 4 h à l'écran verrouillé. C'est largement assez pour une journée de piste.

### La limite à connaître : le rythme de rafraîchissement

Apple ne publie pas de chiffre pour les mises à jour locales (`Activity.update`) : c'est un budget qui dépend de l'appareil. Un ingénieur Apple a écrit sur les forums qu'ils *« throttle update frequencies »*. Ce qu'on a fait pour vivre avec :

1. Un intervalle réglable (0,5 / 1 / 2 / 5 s, 1 s par défaut). L'écran Diagnostic compte les mises à jour réellement envoyées par minute : on mesurera le vrai plafond dans la voiture.
2. À chaque mise à jour, on envoie **le pic de turbo de l'intervalle**, pas seulement la dernière valeur. On ne rate donc pas une pointe entre deux rafraîchissements.
3. Une date de péremption (`staleDate`) : si l'adaptateur est perdu, CarPlay affiche « Signal perdu » au lieu de valeurs figées.
4. Pour le vrai temps réel (aiguille fluide), l'iPhone sur un support reste imbattable.

## 2. Récupérer les données vite : ELM327 / Veepeak OBDCheck BLE+

- Le Veepeak BLE+ est un adaptateur ELM327 compatible ; une source récente le dit équipé d'une puce STN2120, plus rapide que les clones. Sur iPhone il passe en Bluetooth LE ; **il ne faut pas l'appairer dans Réglages > Bluetooth**.
- Service BLE : FFF0 d'après plusieurs sources, mais elles se contredisent sur le rôle de FFF1 et FFF2 (lecture ou écriture). L'app choisit donc les caractéristiques d'après leurs propriétés (notify / write), pas d'après leur UUID. Elle connaît aussi FFE0, 18F0 (vLinker / OBDLink) et le service Vgate.
- Accélérations mises en place, avec retour automatique en mode prudent si la voiture ne suit pas :
  - **Écho, sauts de ligne et espaces coupés** (`ATE0 ATL0 ATS0`) : réponses plus courtes en Bluetooth.
  - **Requêtes groupées** : jusqu'à 6 PID en une seule question, par exemple « `01700C0B05` ». En CAN, c'est un seul aller-retour Bluetooth au lieu de 4.
  - **Nombre de réponses annoncé** (`010C1` : la voiture répond une fois, l'ELM n'attend pas son délai de garde). Utilisé seulement quand un seul calculateur répond.
  - **Adressage direct du moteur** (`ATSH7E0`) : la boîte de vitesses ne répond plus en parallèle, ce qui rend l'annonce du nombre de réponses fiable.
  - **Délai adaptatif agressif** (`ATAT2`), avec retour en `ATAT1` si trop de « NO DATA ».
  - **Priorités** : turbo et régime à chaque cycle ; températures et vitesse toutes les secondes ; pression atmosphérique toutes les 15 s ; tension batterie toutes les 5 s.
- Pression de turbo :
  - **PID 0x70** (capteur de suralimentation, 1/32 kPa, jusqu'à 2 048 kPa) en priorité. Il donne aussi la **consigne** du calculateur (repère jaune sur la jauge).
  - Sinon **PID 0x87** (MAP étendu).
  - Sinon **PID 0x0B** (MAP classique, **plafonné à 255 kPa absolus ≈ 1,54 bar relatif**). Un 320d d'origine pousse autour de cette valeur : l'app affiche « capteur saturé » si on touche le plafond.
  - Turbo relatif = pression absolue − pression atmosphérique (PID 0x33, sinon mesurée moteur arrêté, sinon 1 013 hPa).

## 3. Spécial BMW 320d E90

- **Protocole selon la date de fabrication** : les E90 produites à partir de mars 2007 environ ont la prise OBD en CAN (« D-CAN », rapide). Les plus anciennes sont en K-line (KWP2000), nettement plus lente : quelques mesures par seconde seulement. L'app détecte et gère les deux (en-têtes, format KWP, ISO-TP). L'écran Diagnostic affiche le protocole trouvé. *Cette date charnière vient de connaissances générales sur la gamme ; elle n'a pas été confirmée par une source officielle BMW lors de cette recherche.*
- Une note publique sur le bus CAN de l'E90 associe le PID 0x0B au capteur de pression de suralimentation (« OBD_PID0B_Air_pSensPIntkVUs »). Des utilisateurs de 335d lisent aussi le turbo par le PID 0x70. On s'attend donc à ce que le turbo soit lisible, à vérifier sur ta voiture (liste des PID supportés dans Diagnostic).
- Pour aller plus loin que l'OBD standard (consigne et réel avec plus de précision, températures de boîte, EGT…), il faudrait parler le protocole BMW propriétaire (DDE via KWP2000/UDS). C'est une étape ultérieure possible.

## 4. Installer sans Mac et sans payer

- La compilation se fait sur un Mac de GitHub Actions (gratuit et illimité pour un dépôt public) : `project.yml` (XcodeGen) → `xcodebuild` → IPA non signée publiée en release.
- La signature et l'installation se font depuis Ubuntu avec **iloader** (open source, maintenu : v2.4.1 du 28/10/2026), avec un identifiant Apple gratuit, par câble USB.
- Limites du compte gratuit : l'app expire au bout de **7 jours** (il faut la réinstaller), 3 apps maximum, 10 identifiants d'app par semaine (l'app + l'extension Live Activity = 2).
- Risque connu (octobre 2026) : iloader a des bugs ouverts sur iOS 27 : apps tuées au lancement (« Invalid Page »), extensions refusées dans certains cas, profils « bannis ». Si ça bloque : SideStore (installé lui-même par iloader), ou le compte payant (99 €/an) avec TestFlight. Pas d'expiration à 7 jours, et le workflow GitHub peut être étendu pour envoyer directement sur TestFlight.

## 5. Idées pour la suite

- **Widget CarPlay** « dernière session » (pic de turbo, régime max, temp. max), et widget de l'écran d'accueil.
- **Chrono au tour** avec le GPS (déjà actif en arrière-plan), courbes turbo / régime par tour, export CSV.
- **Alertes** : surchauffe d'eau via `update(_:alertConfiguration:)` (bannière CarPlay), shift-light sonore.
- **Protocole BMW** pour des données hors OBD standard.
- **Émulateur d'adaptateur BLE sous Linux** (BlueZ) pour tester la liaison Bluetooth sans la voiture.

## Sources

- Apple, *CarPlay Developer Guide* (13 octobre 2026) : https://developer.apple.com/download/files/CarPlay-Developer-Guide.pdf (pages 3, 7, 10, 11, 13, 15)
- Apple, *Displaying live data with Live Activities* : https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities
- Apple, *Creating custom views for Live Activities* : https://developer.apple.com/documentation/activitykit/creating-custom-views-for-live-activities
- Apple, *Keeping a widget up to date* (budget de 40 à 70 rafraîchissements par jour) : https://developer.apple.com/documentation/widgetkit/keeping-a-widget-up-to-date
- Apple, *ActivityKit updates* : https://developer.apple.com/documentation/updates/activitykit
- WWDC25 « Turbocharge your app for CarPlay » : https://developer.apple.com/videos/play/wwdc2025/216/
- WWDC26 « Live Activities essentials » : https://developer.apple.com/videos/play/wwdc2026/223/
- WWDC26 « Rev up your CarPlay app » : https://developer.apple.com/videos/play/wwdc2026/212/
- Forum Apple, limitation des mises à jour de Live Activity : https://developer.apple.com/forums/thread/748569
- PID OBD-II (formules, bitmaps) : https://en.wikipedia.org/wiki/OBD-II_PIDs
- ELM327, nombre de réponses et requêtes multi-PID : https://www.scantool.net/scantool/downloads/103/elm327dsh.pdf et https://github.com/FlappedEar/BetterDriver/pull/261
- UUID BLE Veepeak : http://forum.gps-laptimer.de/viewtopic.php?t=5332 et https://botmonster.com/smart-home/home-assistant-vehicle-tracking-obd2-ble/
- E90, PID turbo : https://gist.github.com/MorGuux/832054bcbe6c1207b1f3075d5ecf6a4a et https://www.e90post.com/forums/showthread.php?t=1118429&page=4
- Runners macOS 26 de GitHub : https://github.blog/changelog/2026-02-26-macos-26-is-now-generally-available-for-github-hosted-runners/
- iloader : https://github.com/nab138/iloader (issues #767, #1082, #1091 pour iOS 27)
