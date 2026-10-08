import Photos
import CoreLocation

/// Zugriff auf die Fotos-Mediathek: Album anlegen und Medien mit Originaldatum importieren.
enum PhotoLibrary {

    static func requestFullAccess() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else { throw ImportError.photoAccessDenied }
    }

    /// Gibt die ID des Albums zurück und legt es an, falls es noch nicht existiert.
    static func albumID(named name: String) async throws -> String {
        if let existing = fetchAlbum(named: name) { return existing.localIdentifier }
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
        }
        guard let created = fetchAlbum(named: name) else { throw ImportError.albumCreationFailed }
        return created.localIdentifier
    }

    private static func fetchAlbum(named name: String) -> PHAssetCollection? {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", name)
        return PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: options).firstObject
    }

    /// Importiert eine Datei. `creationDate` sorgt dafür, dass das Memory in «Alle Fotos»
    /// am richtigen Tag erscheint – nicht am Tag des Imports.
    static func importAsset(file: URL, kind: MediaKind, date: Date,
                            location: CLLocation?, albumID: String) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = false
            options.originalFilename = file.lastPathComponent
            request.addResource(with: kind == .video ? .video : .photo, fileURL: file, options: options)
            request.creationDate = date
            request.location = location

            if let placeholder = request.placeholderForCreatedAsset,
               let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject,
               let albumRequest = PHAssetCollectionChangeRequest(for: album) {
                albumRequest.addAssets([placeholder] as NSArray)
            }
        }
    }
}
