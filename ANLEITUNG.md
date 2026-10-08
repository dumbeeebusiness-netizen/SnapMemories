# SnapMemories ohne Mac – Build in der Cloud + Installation mit Sideloadly

## 1. App bauen lassen (GitHub, einmalig)
GitHub baut die App auf einem macOS-Server zu einer `SnapMemories.ipa`. Das übernimmt Claude, sobald dein GitHub-Konto verbunden ist.
Den fertigen Build findest du im Repository unter **Releases › latest › SnapMemories.ipa**. Lade ihn in den Download-Ordner herunter.

## 2. Vorbereitung auf dem PC
- **Sideloadly** von https://sideloadly.io installieren.
- **iTunes** (die Version von apple.com, *nicht* aus dem Microsoft Store) bzw. «Apple Devices» installieren, damit Windows das iPhone erkennt.

## 3. Vorbereitung auf dem iPhone
- Mit dem Kabel an den PC anschliessen und «Diesem Computer vertrauen» bestätigen.
- Einstellungen › Datenschutz & Sicherheit › **Entwicklermodus** einschalten. Der Schalter erscheint oft erst nach dem ersten Installationsversuch; danach startet das iPhone neu.

## 4. Installieren mit Sideloadly
1. Sideloadly öffnen. Oben links sollte dein iPhone stehen.
2. Die `SnapMemories.ipa` ins Fenster ziehen.
3. Bei «Apple ID» deine normale Apple-ID eintragen und **Start** klicken.
   - Das Passwort geht nur an Apple, um ein kostenloses Entwickler-Zertifikat zu erstellen. Bei aktivierter Zwei-Faktor-Authentifizierung den Code vom iPhone eingeben.
4. Auf dem iPhone: Einstellungen › Allgemein › **VPN & Geräteverwaltung** › deine Apple-ID › **Vertrauen**.
5. SnapMemories öffnen.

> Mit einer kostenlosen Apple-ID läuft die App **7 Tage**. Danach einfach in Sideloadly nochmals auf Start klicken. Für den Import reicht das.

## 5. Memories importieren
1. Snapchat › Profil › Einstellungen › **Meine Daten** › «Export your Memories» aktivieren › Zeitraum «Gesamte Zeit» › absenden.
2. Wenn die Mail kommt, die ZIP-Datei(en) **direkt auf dem iPhone** herunterladen. In Safari landen sie unter Dateien › Downloads.
   - Alternativ auf dem PC herunterladen und per iTunes › Dateifreigabe › SnapMemories aufs iPhone kopieren.
3. SnapMemories › **Export-Dateien wählen** › alle ZIPs markieren › prüfen › **Importieren**.
4. Beim Zugriff auf die Fotos **«Vollzugriff»** erlauben.
5. Die App geöffnet lassen, bis der Import fertig ist.

Das Ergebnis ist das Album **«Snapchat Memories»**: alles chronologisch und mit Originaldatum, so dass die Memories auch in «Alle Fotos» am richtigen Tag erscheinen.

## Probleme
- **Sideloadly findet das iPhone nicht** → iTunes von apple.com installieren, Kabel neu einstecken, «Vertrauen» bestätigen.
- **«Maximum number of apps»** → Mit einer kostenlosen Apple-ID sind max. 3 eigene Apps gleichzeitig erlaubt. Eine alte gesideloadete App löschen.
- **App öffnet nicht mehr** → Die 7 Tage sind abgelaufen. In Sideloadly erneut auf Start klicken; der Import-Verlauf bleibt erhalten.
