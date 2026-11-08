# AetherEngine dans Nyx : copie vendue et modifications

Ce dossier est la source d'**AetherEngine 7.25.1** (tag `7.25.1`, révision `8f3e73cd4045ff3f4ea09b40b7f1ef3b7f5068e5`,
<https://github.com/superuser404notfound/AetherEngine>), copiée telle quelle le 2026-11-07 : les 972 fichiers que l'amont
suit, sans `.git`. Licence : `LICENSE` (LGPL-3 avec l'exception App Store / DRM de l'auteur), inchangée.

Le paquet se construit comme l'amont (`Package.swift` et `Package.resolved` inchangés) : FFmpegBuild 3.6.0, LibDovi
2.1.0, SMBClient 0.3.1, résolus par Git comme avant. Seul `NyxLecteur` le lit, par `.package(path: "../Vendor/AetherEngine")`.

## 2026-11-07 : sur le Mac, le serveur HLS local n'écoute que sur 127.0.0.1

**Pourquoi.** App Review bloque l'app Mac (règle 2.4.5, question du 2026-11-02) sur le droit
`com.apple.security.network.server` : « Can you confirm the server binds only to 127.0.0.1 (not 0.0.0.0)…? ». L'amont lie
`HLSLocalServer` à `0.0.0.0` sur toutes les plateformes, pour que l'iPhone serve sa boucle locale à un récepteur AirPlay
vidéo (#86) ; la 7.32.1 le fait encore. Sur le Mac, AirPlay ne porte que le son dans Nyx (le sélecteur de sortie n'a pas
d'AVPlayer, `Apps/Mac/Lecture/SelecteurDeSortie.swift`) : personne n'a à joindre ce serveur depuis le réseau. Décision de
Marc, le 2026-11-07 : corriger sur le Mac seulement ; l'iPhone et l'Apple TV ne changent pas.

**Ce qui change, sur macOS seulement** (`#if os(macOS)` ; iOS, tvOS et visionOS compilent exactement le code de l'amont) :

1. `Sources/AetherEngine/Network/HLSLocalServer.swift`, `start()` : `bind()` sur `127.0.0.1` au lieu de `0.0.0.0`.
2. `Sources/AetherEngine/AetherEngine.swift`, `airPlayPlaybackURL(base:playlist:)` : rend `nil`. La lecture externe est
   suivie sur macOS (KVO de `isExternalPlaybackActive`, `#if !os(visionOS) && !os(tvOS)`) et `airPlayActive` peut y passer
   à vrai. `airPlayAdjustedPlayback` et le relais de sous-titres (`AetherEngine+Loading.swift`) sont déjà propres à iOS,
   mais `airPlayHostSwapped` et le repli sur la playlist media ne l'étaient pas : la porte de démarrage (#35, trois
   `swapItem`), le repli après un refus du master (`fallbackURL`) et `handleRefusedAirPlayMaster` auraient donné à
   AVPlayer l'adresse du Mac sur le réseau, que le serveur n'écoute plus. Avec `nil`, chaque appelant garde son URL
   `127.0.0.1` (`airPlayHostSwapped` devient l'identité).
3. Tests : `Tests/AetherEngineTests/NyxLoopbackOnMacTests.swift` (ajouté : la boucle locale répond ; l'adresse du Mac sur
   le réseau est refusée ; aucune adresse du réseau n'est fabriquée) et `HLSLocalServerSlowPeerTests.swift` (le test
   « LAN peers cannot take the slots kept for loopback » ne tourne plus sur macOS, où aucun pair du réseau n'arrive).

**Vérifié dans la source** : c'est le seul socket du moteur (`socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)` dans
`HLSLocalServer.start()`) ; `HLSOriginRelay` et `RemoteHLSSubtitleProxy` se montent sur un `HLSLocalServer` et n'ouvrent
rien d'autre ; ni `NWListener` ni `CFSocket` ; les fixtures d'`aetherctl` (outil en ligne de commande, jamais livré dans
l'app) écoutent déjà sur `127.0.0.1`. Le jeton de chemin de 128 bits, l'en-tête à délai et le reste du serveur sont ceux
de l'amont.

**Lancer les tests** : `swift test --package-path Vendor/AetherEngine --scratch-path .build/swift-moteur --filter
NyxLoopbackOnMacTests` (la porte `outils/verifie.sh` le fait, et vérifie aussi la présence des deux `#if os(macOS)`).
Sans le correctif, « L'adresse du Mac sur le réseau ne joint pas le serveur » échoue (vérifié le 2026-11-07).

**Monter de version** : recopier le nouveau tag ici (tel quel, un commit à part), réappliquer ce diff, relancer les tests
ci-dessus et la grille de `docs/mesures-lecture.md`.

### La source modifiée, pour les utilisateurs

La licence veut la source correspondante, modifications comprises, disponible pour qui reçoit l'app. Le dépôt NyxTV
n'est pas public : 🔴 **l'adresse publique reste à choisir (Marc)** et se met dans
`Apps/Commun/Ecrans/Reglages/EcranAPropos.swift` (`adresseDesSourcesDuMoteur`). L'écran « Licences et sources » dit déjà
qu'AetherEngine est modifié par Nyx ; `outils/verifie.sh` rappelle l'adresse tant qu'elle est vide.

### Le diff exact (contre la 7.25.1 de l'amont)

Le fichier `NyxLoopbackOnMacTests.swift` est entièrement nouveau ; il n'est pas répété ici.

```diff
diff --git a/Vendor/AetherEngine/Sources/AetherEngine/AetherEngine.swift b/Vendor/AetherEngine/Sources/AetherEngine/AetherEngine.swift
index e7cef3c..db90736 100644
--- a/Vendor/AetherEngine/Sources/AetherEngine/AetherEngine.swift
+++ b/Vendor/AetherEngine/Sources/AetherEngine/AetherEngine.swift
@@ -1,3 +1,5 @@
+// Modifié par Nyx le 2026-11-07 (App Review 2.4.5, droit network.server du Mac) : airPlayPlaybackURL rend nil sur macOS : jamais d'adresse du réseau pour AirPlay.
+// Copie de la 7.25.1 d'AetherEngine (LGPL-3 avec exception App Store) ; le détail : Vendor/AetherEngine/NYX-MODIFICATIONS.md.
 import Foundation
 import Darwin.Mach
 import QuartzCore
@@ -6687,8 +6689,17 @@ public final class AetherEngine: ObservableObject {
     /// the reduced HDR master or plain media for HDR. See `AirPlayPlaylistDecision`.
     func airPlayPlaybackURL(base: URL,
                             playlist: AirPlayPlaylistDecision.ReceiverPlaylist = .media) -> URL? {
+        #if os(macOS)
+        // Nyx (2026-11-07) : sur le Mac, l'écoute reste sur la boucle locale (App Review 2.4.5), donc jamais d'adresse
+        // du réseau. La lecture externe est suivie sur macOS (`isExternalPlaybackActive`) et `airPlayActive` peut y
+        // passer à vrai ; sans ce garde-fou, la porte de démarrage (#35), le repli sur la playlist media et
+        // `handleRefusedAirPlayMaster` donneraient à AVPlayer une adresse que le serveur n'écoute plus. nil : chaque
+        // appelant garde son URL 127.0.0.1. Voir Vendor/AetherEngine/NYX-MODIFICATIONS.md.
+        return nil
+        #else
         guard let lanIP = HLSLocalServer.localActiveIPAddress() else { return nil }
         return AirPlayPlaylistDecision.receiverURL(base: base, lanIP: lanIP, playlist: playlist)
+        #endif
     }
 
     #if os(tvOS) || os(iOS)
diff --git a/Vendor/AetherEngine/Sources/AetherEngine/Network/HLSLocalServer.swift b/Vendor/AetherEngine/Sources/AetherEngine/Network/HLSLocalServer.swift
index 082a04d..124eb6d 100644
--- a/Vendor/AetherEngine/Sources/AetherEngine/Network/HLSLocalServer.swift
+++ b/Vendor/AetherEngine/Sources/AetherEngine/Network/HLSLocalServer.swift
@@ -1,3 +1,5 @@
+// Modifié par Nyx le 2026-11-07 (App Review 2.4.5, droit network.server du Mac) : start() lie l'écoute à 127.0.0.1 sur macOS (0.0.0.0 ailleurs, inchangé).
+// Copie de la 7.25.1 d'AetherEngine (LGPL-3 avec exception App Store) ; le détail : Vendor/AetherEngine/NYX-MODIFICATIONS.md.
 import Darwin
 import Foundation
 
@@ -560,7 +562,14 @@ final class HLSLocalServer: @unchecked Sendable {
         // onto a new server, but a readiness-gate swap (`airPlayHostSwapped`) and a held edge re-read after a
         // reload hand the LAN URL to the server already listening. LAN exposure is bounded instead by the
         // head deadlines and the loopback reserve in the accept loop.
+        #if os(macOS)
+        // Nyx (2026-11-07) : sur le Mac, l'écoute reste sur la boucle locale (App Review 2.4.5). L'AirPlay du Mac ne
+        // porte que le son (pas d'image confiée à un récepteur), et `airPlayPlaybackURL` ne réécrit plus l'adresse sur
+        // macOS : personne n'a à joindre ce serveur depuis le réseau. Voir Vendor/AetherEngine/NYX-MODIFICATIONS.md.
+        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
+        #else
         addr.sin_addr.s_addr = inet_addr("0.0.0.0")
+        #endif
 
         let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
             ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
diff --git a/Vendor/AetherEngine/Tests/AetherEngineTests/HLSLocalServerSlowPeerTests.swift b/Vendor/AetherEngine/Tests/AetherEngineTests/HLSLocalServerSlowPeerTests.swift
index d360237..d581645 100644
--- a/Vendor/AetherEngine/Tests/AetherEngineTests/HLSLocalServerSlowPeerTests.swift
+++ b/Vendor/AetherEngine/Tests/AetherEngineTests/HLSLocalServerSlowPeerTests.swift
@@ -1,3 +1,5 @@
+// Modifié par Nyx le 2026-11-07 (App Review 2.4.5, droit network.server du Mac) : le test des pairs du réseau est désactivé sur macOS.
+// Copie de la 7.25.1 d'AetherEngine (LGPL-3 avec exception App Store) ; le détail : Vendor/AetherEngine/NYX-MODIFICATIONS.md.
 import Foundation
 import Testing
 @testable import AetherEngine
@@ -59,8 +61,10 @@ struct HLSLocalServerSlowPeerTests {
                 "the second request on an authenticated keep-alive connection was not answered")
     }
 
+    // Nyx (2026-11-07) : sur le Mac, le serveur n'écoute que sur 127.0.0.1 ; aucun pair du réseau ne l'atteint, ce que
+    // `NyxLoopbackOnMacTests` vérifie à la place. Voir Vendor/AetherEngine/NYX-MODIFICATIONS.md.
     @Test("LAN peers cannot take the slots kept for loopback",
-          .enabled(if: HLSLocalServer.localActiveIPAddress() != nil))
+          .enabled(if: !nyxEcouteSurLaBoucleLocaleSeulement && HLSLocalServer.localActiveIPAddress() != nil))
     func lanPeersLeaveLoopbackSlots() async throws {
         let lanIP = try #require(HLSLocalServer.localActiveIPAddress())
         let server = HLSLocalServer(provider: StubProvider(), unauthenticatedHeadSeconds: 60)
```

## Monter de version (rappel de Marc, 2026-11-07 : « les prochaines versions, il faudra re-pull »)

La copie vendue ne suit plus l'amont toute seule : chaque nouvelle version d'AetherEngine se reprend à la main.

1. Dans la copie publique (`MarcBelleperche/AetherEngine`) : récupérer le tag de l'amont, puis repartir de lui avec le
   correctif : `git fetch upstream --tags`, `git switch -c nyx-<version> <version>`, `git cherry-pick <commit du correctif>`
   (deux blocs `#if os(macOS)`, un test, ce fichier). Résoudre si l'amont a touché `HLSLocalServer.start()` ou
   `airPlayPlaybackURL`, puis pousser la branche `nyx-<version>`.
2. Ici : remplacer `Vendor/AetherEngine/` par cette branche (sans `.git`), relancer `outils/verifie.sh` : il refuse une copie
   sans les deux `#if os(macOS)` et lance `NyxLoopbackOnMacTests`.
3. Mettre à jour `adresseDesSourcesDuMoteur` (`Apps/Commun/Ecrans/Reglages/EcranAPropos.swift`) vers la nouvelle branche.

📌 Pour ne plus avoir à le faire : proposer à l'amont une option d'écoute en boucle locale (ou le `#if os(macOS)` tel
quel). Si l'auteur l'accepte, on revient au paquet distant et la copie vendue disparaît.
