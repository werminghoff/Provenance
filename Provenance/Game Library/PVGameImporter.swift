//  Converted to Swift 4 by Swiftify v4.1.6613 - https://objectivec2swift.com/
//
//  PVGameImporter.swift
//  Provenance
//
//  Created by James Addyman on 01/04/2015.
//  Copyright (c) 2015 James Addyman. All rights reserved.
//

import Foundation
import RealmSwift
import CoreSpotlight

struct ImportCanidateFile {
    var filePath : URL
    var md5 : String? {
        if let cached = cache.md5 {
            return cached
        } else {
            let computed = FileManager.default.md5ForFile(atPath: filePath.path, fromOffset: 0)
            cache.md5 = computed
            return computed
        }
    }
    
    init(filePath: URL) {
        self.filePath = filePath
    }
    
    // Store a cache in a nested class.
    // The struct only contains a reference to the class, not the class itself,
    // so the struct cannot prevent the class from mutating.
    private class Cache {
        var md5 : String?
    }
    private var cache = Cache()
}

public extension PVGameImporter {
    
    // MARK: - Paths
    @objc
    var documentsPath : URL { return PVEmulatorConfiguration.documentsPath }

    @objc
    var romsImporPath : URL { return PVEmulatorConfiguration.romsImportPath }
    
    @objc
    var conflictPath : URL { return PVEmulatorConfiguration.documentsPath.appendingPathComponent("conflict", isDirectory: true) }

    func path(forSystemID systemID: String) -> String? {
        return systemToPathMap[systemID]
    }
    
    func systemIDsForRom(at path: URL) -> [String]? {
        let fileExtension: String = path.pathExtension.lowercased()
        return romExtensionToSystemsMap[fileExtension]
    }
    
    internal func isCDROM(_ romFile: ImportCanidateFile) -> Bool {
        let cdExtensions = PVEmulatorConfiguration.supportedCDFileExtensions
        let ext = romFile.filePath.pathExtension
        
        return cdExtensions.contains(ext)
    }
    
    @objc
    func calculateMD5(forGame game : PVGame ) -> String? {
        var offset : UInt = 0
        if game.system == .SNES {
            offset = 16
        }
        
        let romPath = documentsPath.appendingPathComponent(game.romPath, isDirectory: false)
        let fm = FileManager.default
        if !fm.fileExists(atPath: romPath.path) {
            ELOG("Cannot find file at path: \(romPath)");
            return nil
        }
        
        return fm.md5ForFile(atPath: romPath.path, fromOffset: offset)
    }
    
    @objc
    func importFiles(atPaths paths: [URL]) -> [URL] {
        let sortedPaths = paths.sorted { (obj1, obj2) -> Bool in
            
            let obj1Filename = obj1.lastPathComponent
            let obj2Filename = obj2.lastPathComponent
            
            let obj1Extension = obj1.pathExtension
            let obj2Extension = obj2.pathExtension
            
            // Check m3u
            if obj1Extension == "m3u" && obj2Extension == "m3u" {
                return obj1Filename > obj2Filename
            }
            else if obj1Extension == "m3u" {
                return true
            }
            else if obj2Extension == "m3u" {
                return false
            }
            // Check cue
            else if obj1Extension == "cue" && obj2Extension == "cue" {
                return obj1Filename > obj2Filename
            }
            else if obj1Extension == "cue" {
                return true
            }
            else if obj2Extension == "cue" {
                return false
            }
            // Standard sort
            else {
                return obj1Filename > obj2Filename
            }
        }
        
        // Make ImportCanidateFile structs to hold temporary metadata for import and matching
        // This is just the path and a lazy loaded md5
        let canidateFiles = sortedPaths.map { (path) -> ImportCanidateFile in
            return ImportCanidateFile(filePath: path)
        }

        // do CDs first to avoid the case where an item related to CDs is mistaken as another rom and moved
        // before processing its CD cue sheet or something
        let updatedCanidateFiles = canidateFiles.flatMap { canidate -> ImportCanidateFile? in
            if FileManager.default.fileExists(atPath: canidate.filePath.path) {
                if isCDROM(canidate), let movedToPaths = moveCDROM(toAppropriateSubfolder: canidate) {
                    
                    // Found a CD, can add moved files now to newPaths
                    let pathsString = {return movedToPaths.map{ $0.path }.joined(separator: ", ") }
                    VLOG("Found a CD. Moved files to the following paths \(pathsString())")
                    
                    // Return nil since we don't need the ImportCanidateFile anymore
                    // Files are already moved and imported to database (in theory),
                    // or moved to conflicts dir and already set the conflists flag - jm
                    return nil
                } else {
                    return canidate
                }
            } else {
                if canidate.filePath.pathExtension != "bin" {
                    WLOG("File should have existed at \(canidate.filePath) but it might have been moved")
                }
                return nil
            }
        }
        
        // Add new paths from remaining canidate files
        // CD files that matched a system will be remove already at this point
        let newPaths = updatedCanidateFiles.flatMap { canidate -> URL? in
            if FileManager.default.fileExists(atPath: canidate.filePath.path) {
                if let newPath = moveROM(toAppropriateSubfolder: canidate) {
                    return newPath
                }
            }
            return nil
        }
        
        return newPaths
    }
    
    func startImport(forPaths paths: [URL]) {
        serialImportQueue.async(execute: {() -> Void in
            let newPaths = self.importFiles(atPaths: paths)
            self.getRomInfoForFiles(atPaths: newPaths, userChosenSystem: nil)
            if self.completionHandler != nil {
                DispatchQueue.main.sync(execute: {() -> Void in
                    self.completionHandler?(self.encounteredConflicts)
                })
            }
        })
    }
}

public extension PVGameImporter {
    func updateSystemToPathMap() -> [String: URL] {
        let map = PVEmulatorConfiguration.availableSystemIdentifiers.reduce([String: URL]()) { (dict, systemID) -> [String:URL] in
            var dict = dict
            dict[systemID] = documentsPath.appendingPathComponent(systemID, isDirectory: true)
            return dict
        }

        return map
    }
    
    func updateromExtensionToSystemsMap() -> [String: [String]] {
        return PVEmulatorConfiguration.availableSystemIdentifiers.reduce([String:[String]](), { (dict, systemID) -> [String:[String]] in
            if let extensionsForSystem = PVEmulatorConfiguration.fileExtensions(forSystemIdentifier: systemID) {
                // Make a new dict of [ext : systemID] for each ext in extions for that ID, then merge that dictionary with the current one,
                // if the dictionary already has that key, the arrays are joined so you end up with a ext mapping to multpiple systemIDs
                let extsToCurrentSystemID = extensionsForSystem.reduce([String:[String]](), { (dict, ext) -> [String:[String]] in
                    var dict = dict
                    dict[ext] = [systemID]
                    return dict
                })
                
                return dict.merging( extsToCurrentSystemID , uniquingKeysWith: {  var newArray = $0; newArray.append(contentsOf: $1); return newArray;  })
            } else {
                WLOG("No extensions found for \(systemID). That's unexpected.")
                return dict
            }
        })
    }
}

public extension PVGameImporter {

    /**
     Import a specifically named image file to the matching game.
     
     To update “Kart Fighter.nes”, use an image named “Kart Fighter.nes.png”.
     
     @param imageFullPath The artwork image path
     @return The game that was updated
     */
    @objc
    class func importArtwork(fromPath imageFullPath: URL) -> PVGame? {
        
        // Check the file exists (and is not a directory for some reason)
        var isDirectory :ObjCBool = false
        let fileExists = FileManager.default.fileExists(atPath: imageFullPath.path, isDirectory: &isDirectory)
        if !fileExists || isDirectory.boolValue {
            WLOG("File doesn't exist or is directory at \(imageFullPath)")
            return nil
        }
        
        // Make sure we always delete the image even on early error returns
        defer {
            do {
                try FileManager.default.removeItem(at: imageFullPath)
            } catch {
                ELOG("Failed to delete image at path \(imageFullPath) \n \(error.localizedDescription)")
            }
        }
        
        // Read the data
        let coverArtFullData : Data
        do {
            coverArtFullData = try Data.init(contentsOf: imageFullPath, options: [])
        } catch {
            ELOG("Couldn't read data from image file \(imageFullPath.path)\n\(error.localizedDescription)")
            return nil
        }
        
        // Create a UIImage from the Data
        guard let coverArtFullImage = UIImage(data: coverArtFullData) else {
            ELOG("Failed to create Image from data")
            return nil
        }
        
        // Scale the UIImage to our desired max size
        guard let coverArtScaledImage = coverArtFullImage.scaledImage(withMaxResolution: Int(PVThumbnailMaxResolution)) else {
            ELOG("Failed to create scale image")
            return nil
        }

        // Create new Data from scaled image
        guard let coverArtScaledData = UIImagePNGRepresentation(coverArtScaledImage) else {
            ELOG("Failed to create data respresentation of scaled image")
            return nil
        }
        
        // Hash the image and save to cache
        let hash: String = (coverArtScaledData as NSData).md5Hash
        
        do {
            try PVMediaCache.writeData(toDisk: coverArtScaledData, withKey: hash)
        } catch {
            ELOG("Failed to save artwork to cache: \(error.localizedDescription)")
            return nil
        }
        
        // Trim the extension off the filename
        let gameFilename: String = imageFullPath.deletingPathExtension().lastPathComponent
        
        // Figure out what system this belongs to by extension
        // Hey, how is this going to work if we just stripped it?
        let gameExtension = imageFullPath.pathExtension
        
        guard let systemIDs: [String] = PVEmulatorConfiguration.systemIdentifiers(forFileExtension: gameExtension) else {
            ELOG("No system for extension \(gameExtension)")
            return nil
        }
        
        let cdBasedSystems = PVEmulatorConfiguration.cdBasedSystemIDs
        let couldBelongToCDSystem = !Set(cdBasedSystems).isDisjoint(with: Set(systemIDs))
        let database = RomDatabase.sharedInstance

        // Skip CD systems for non special extensions
        if (couldBelongToCDSystem && (gameExtension.lowercased() != "cue" || gameExtension.lowercased() != "m3u")) || systemIDs.count > 1 {
            // We could get here with Sega games. They use .bin, which is CD extension.
            // See if we can match any of the potential paths to a current game
            // See if we have any current games that could match based on searching for any, [systemIDs]/filename
            let existingGames = findAnyCurrentGameThatCouldBelongToAnyOfTheseSystemIDs(systemIDs, romFilename:gameFilename)
            if existingGames.count == 1, let onlyMatch = existingGames.first {
                ILOG("We found a hit for artwork that could have been belonging to multiple games and only found one file that matched by systemid/filename. The winner is \(onlyMatch.title) for \(onlyMatch.systemIdentifier)")
                do {
                    try database.writeTransaction {
                        onlyMatch.customArtworkURL = hash
                    }
                } catch {
                    ELOG("Couldn't update game \(onlyMatch.title) with new artwork URL")
                }
                return onlyMatch
            } else if existingGames.count > 1{
                ELOG(
                    """
                    We got to the unlikely scenario where an extension is possibly a CD binary file, \
                    or belongs to a system, and had multiple games that matmched the filename under more than one core.
                    Since there's no sane way to determine which game it belonds to, we must quit here. Sorry.
                    """)
                return nil
            } else {
                ELOG("System for extension \(gameExtension) is a CD system and {\(gameExtension)} not the right matching file type of cue or m3u")
                return nil
            }
        }
        
        // We already verified that above that there's 1 and only 1 system ID that matmched so force first!
        let systemID = systemIDs.first!
        
        // TODO: This will break if we move the ROMS to a new spot
        let gamePartialPath: String = URL(fileURLWithPath: systemID, isDirectory:true).appendingPathComponent(gameFilename).path
        if gamePartialPath.isEmpty {
            ELOG("Game path was empty")
            return nil
        }
        
        // Find the game in the database
        guard let game = database.all(PVGame.self, where: #keyPath(PVGame.romPath), value: gamePartialPath).first else {
            ELOG("Couldn't find game for path \(gamePartialPath)")
            return nil
        }

        do {
            try database.writeTransaction {
                game.customArtworkURL = hash
            }
        } catch {
            ELOG("Couldn't update game with new artwork URL")
        }
        
        return game
    }
    
    fileprivate class func findAnyCurrentGameThatCouldBelongToAnyOfTheseSystemIDs(_ systemIDs : [String], romFilename : String) -> Results<PVGame> {
        // Check if existing ROM
        // Use an OR predicate to see if any game.romPath : String, contains any of the matched systems
        // This seems sloppy but it woks, could use a block predicate to I suppose

        // What would the paths looks like partially
        let potentialExistingRomPartialPaths : [String] = systemIDs.map { systemID in
            
            // TODO: WARNING: I'm not sure how this will work because do the PVGames have partial pathings from the Documents dir?
            // And is we use PVEmulatorConfiguration.romDirectory, we don't know how many sub-dirs to match before we get to the systemid
            // Maybe we could use MD5 matching instead... fuck it I'm tired and this is such an edge case - jm
            // PVEmulatorConfiguration.romDirectory(forSystemIdentifier: systemID).appendingPathComponent(filename).path
            
            // For now do it this way, but it may break if and when we change the structure of ROM folders
            return "\(systemID)/\(romFilename)"
        }
        
        
        // Predicate version, slower? Probably, has to load each object - jm
        //                    let blockPredicate = NSPredicate(block: { (evaluatedObject, bindings) -> Bool in
        //                        guard let game = evaluatedObject as? PVGame else {
        //                            return false
        //                        }
        //                        let romPath = game.romPath
        //                        return potentialExistingRomPartialPaths { return romPath.contains($0) }
        //
        //                    })
        let database = RomDatabase.sharedInstance
        let allContainsPredicats = potentialExistingRomPartialPaths.map { return NSPredicate(format: "romPath CONTAINS[c] %@", $0) }
        let compoundPredicate = NSCompoundPredicate(orPredicateWithSubpredicates: allContainsPredicats)
        let existingGames = database.all(PVGame.self, filter: compoundPredicate)
        return existingGames
    }
    
    @objc
    func getRomInfoForFiles(atPaths paths: [URL], userChosenSystem chosenSystemID: String? = nil) {
        let database = RomDatabase.sharedInstance
        database.refresh()
        
        paths.forEach { (path) in
            let isDirectory: Bool = !path.isFileURL
            if path.lastPathComponent.hasPrefix(".") || isDirectory {
                VLOG("Skipping file with . as first character or it's a directory")
                return
            }
            autoreleasepool {
                var systemIDsMaybe: [String]? = nil
                
                let urlPath = path
                let filename = urlPath.lastPathComponent
                let fileExtensionLower = urlPath.pathExtension.lowercased()
                
                if let chosenSystemID = chosenSystemID, !chosenSystemID.isEmpty {
                    systemIDsMaybe = [chosenSystemID]
                } else {
                    systemIDsMaybe = PVEmulatorConfiguration.systemIdentifiers(forFileExtension: fileExtensionLower)
                }
                
                // No system found to match this file
                guard var systemIDs = systemIDsMaybe else {
                    ELOG("No system matched extension {\(fileExtensionLower)}")
                    return
                }
                
                // Skip non .m3u/.cue files for CD systems to avoid importing .bins
                // TODO: I think this actaully does nothing... - jm
//                let cdBasedSystems = PVEmulatorConfiguration.cdBasedSystemIDs
//                let couldBelongToCDSystem = !Set(cdBasedSystems).isDisjoint(with: Set(systemIDs))
//                if couldBelongToCDSystem && (fileExtensionLower != "cue" || fileExtension != "m3u") {
//                    WLOG("\(path.lastPathComponent) could belong to a CD and isn't a cue or m3u")
//                    return
//                }
                
                var maybeGame: PVGame? = nil

                if systemIDs.count > 1 {
                    
                    // Try to match by MD5 first
                    if let systemIDMatch = systemId(forROMCanidate: ImportCanidateFile(filePath: urlPath)) {
                        systemIDs = [systemIDMatch]
                    } else {
                        // We have a conflict, multiple systems matched and couldn't find anything by MD5 match
                        let s =  systemIDs.joined(separator: ",")
                        WLOG("\(filename) matched with multiple systems (or none?): \(s). Going to do my best to figure out where it belons")
                        
                        // NOT WHAT WHAT TO DO HERE. -jm
                        // IS IT TOO LATE TO MOVE TO CONFLICTS DIR?
                        
                        let existingGames = PVGameImporter.findAnyCurrentGameThatCouldBelongToAnyOfTheseSystemIDs(systemIDs, romFilename: filename)
                        
                        if existingGames.isEmpty {
                            // NO matches to existing games, I suppose we move to conflicts dir
                            self.encounteredConflicts = true
                            do {
                                try FileManager.default.moveItem(at: path, to: conflictPath)
                                ILOG("It's a new game, so we moved \(filename) to conflicts dir")
                            } catch {
                                ELOG("Failed to move \(urlPath.path) to conflicts dir")
                            }
                            // Worked or failed, we're done with this file
                            return
                        } else if existingGames.count == 1 {
                            // Just one existing game, use that.
                            maybeGame = existingGames.first!
                        } else {
                            // We matched multiple possible systems, and multiple possible existing games
                            // This is a quagmire scenario, I guess also move to conflicts dir...
                            self.encounteredConflicts = true
                            do {
                                try FileManager.default.moveItem(at: path, to: conflictPath)
                                let matchedSystems = systemIDs.joined(separator: ", ")
                                let matchedGames = existingGames.map { $0.romPath }.joined(separator: ", ")
                                WLOG("Scanned game matched with multiple systems {\(matchedSystems)} and multiple existing games \({matchedGames}) so we moved \(filename) to conflicts dir. You figure it out!")
                            } catch {
                                ELOG("Failed to move \(urlPath.path) to conflicts dir.")
                            }
                            return
                        }
                    }
                }
                
                // Should only if we're here, save to !
                let systemID = systemIDs.first!
                
                let partialPath: String = URL(fileURLWithPath: systemID, isDirectory: true).appendingPathComponent(urlPath.lastPathComponent).path
                
                // Deal with m3u files
                //                if fileExtension == "m3u"
                //                {
                //                    // RegEx pattern match the parentheses e.g. " (Disc 1)" and update dictionary with trimmed gameTitle string
                //                    // Grabbed this from OpenEMU - jm
                //                    let newGameTitle = title.replacingOccurrences(of: "\\ \\(Disc.*\\)", with: "", options: .regularExpression, range: Range(0, title.count))
                //                }
                
                
                // Check if we have this game already
                // TODO: We shoulld use the input paths array to make a query that matches any of those paths
                // and then we can use a Set with .contains instead of doing a new query here every times
                // Would instead see if contains first, then query for the full object
                // If we have a matching game from a multi-match above, use that, or run a query by path and see if there's a match there
                if let existingGame = maybeGame ?? database.all(PVGame.self, where: #keyPath(PVGame.romPath), value: partialPath).first {
//                    do {
//                        try database.writeTransaction {
//                            existingGame.romPath = partialPath
//
//                            // TODO: Shoulud check MD5 and delete and make new instance if not equal
//                            // Can't updated MD5 since it's a primary key
//                            if let md5 = calculateMD5(forGame: existingGame) {
//                                existingGame.md5Hash = md5
//                            }
//                        }
                        finishUpdateOrImport(ofGame: existingGame)
//                    } catch {
//                        ELOG("\(error.localizedDescription)")
//                    }
                } else {
                    // New game
                    importToDatabaseROM(atPath: path, systemID: systemID)
                }
            } // autorelease pool
        } // for each
    }
    
    // MARK: - ROM Lookup
    
    @objc
    public func lookupInfo(for game: PVGame) {
        let database = RomDatabase.sharedInstance
        database.refresh()
        if game.md5Hash.isEmpty {
            var offset: UInt = 0
            if let s = game.system, s == .NES {
                offset = 16
                // make this better
            }
            let romFullPath = PVEmulatorConfiguration.documentsPath.appendingPathComponent(game.romPath).path
            
            if let md5Hash = FileManager.default.md5ForFile(atPath: romFullPath, fromOffset: offset) {
                try? database.writeTransaction {
                    game.md5Hash = md5Hash
                }
            }
        }
        
        guard !game.md5Hash.isEmpty else {
            ELOG("Game md5 has was empty")
            return
        }
        
        var resultsMaybe:[[String : Any]]? = nil
        do {
            resultsMaybe = try self.searchDatabase(usingKey: "romHashMD5", value: game.md5Hash.uppercased(), systemID: game.systemIdentifier)
        } catch {
            ELOG("\(error.localizedDescription)")
        }
        
        
        if resultsMaybe == nil || resultsMaybe!.isEmpty {
            let fileName: String = URL(fileURLWithPath:game.romPath, isDirectory:true).lastPathComponent
            // Remove any extraneous stuff in the rom name such as (U), (J), [T+Eng] etc

            let nonCharRange: NSRange = (fileName as NSString).rangeOfCharacter(from: PVGameImporter.charset)
            var gameTitleLen: Int
            if nonCharRange.length > 0 && nonCharRange.location > 1 {
                gameTitleLen = nonCharRange.location - 1
            }
            else {
                gameTitleLen = fileName.count
            }
            let subfileName = String(fileName.prefix(gameTitleLen))
            do  {
                resultsMaybe = try self.searchDatabase(usingKey: "romFileName", value: subfileName, systemID: game.systemIdentifier)
            } catch {
                ELOG("\(error.localizedDescription)")
            }
        }
        
        guard let results = resultsMaybe, !results.isEmpty else {
            DLOG("Unable to find ROM \(game.romPath) in DB");
            try? database.writeTransaction {
                game.requiresSync = false
            }
            return
        }
        
        var chosenResultMaybse: [AnyHashable: Any]? = nil
        for result: [AnyHashable: Any] in results {
            if let region = result["region"] as? String, region == "USA" {
                chosenResultMaybse = result
                break
            }
        }
        
        if chosenResultMaybse == nil {
            chosenResultMaybse = results.first
        }
        
        guard let chosenResult = chosenResultMaybse else {
            DLOG("Unable to find ROM \(game.romPath) in DB");
            return
        }
        
        do {
            try database.writeTransaction {
                game.requiresSync = false
                
                /* Optional results
                     gameTitle
                     boxImageURL
                     region
                     gameDescription
                     boxBackURL
                     developer
                     publisher
                     year
                     genres [comma array string]
                     referenceURL
                     releaseID
                     systemShortName
                     serial
                 */
                
                if let title = chosenResult["gameTitle"] as? String, !title.isEmpty {
                    game.title = title
                }
                
                if let boxImageURL = chosenResult["boxImageURL"] as? String, !boxImageURL.isEmpty {
                    game.originalArtworkURL = boxImageURL
                }
                
                if let regionName = chosenResult["region"] as? String, !regionName.isEmpty {
                    game.regionName = regionName
                }

                if let gameDescription = chosenResult["gameDescription"] as? String, !gameDescription.isEmpty {
                    game.gameDescription = gameDescription
                }

                if let boxBackURL = chosenResult["boxBackURL"] as? String, !boxBackURL.isEmpty {
                    game.boxBackArtworkURL = boxBackURL
                }

                if let developer = chosenResult["developer"] as? String, !developer.isEmpty {
                    game.developer = developer
                }

                if let publisher = chosenResult["publisher"] as? String, !publisher.isEmpty {
                    game.publisher = publisher
                }

                if let genres = chosenResult["genres"] as? String, !genres.isEmpty {
                    game.genres = genres
                }

                if let referenceURL = chosenResult["referenceURL"] as? String, !referenceURL.isEmpty {
                    game.referenceURL = referenceURL
                }

                if let releaseID = chosenResult["releaseID"] as? String, !releaseID.isEmpty {
                    game.releaseID = releaseID
                }

                if let systemShortName = chosenResult["systemShortName"] as? String, !systemShortName.isEmpty {
                    game.systemShortName = systemShortName
                }
                
                if let romSerial = chosenResult["serial"] as? String, !romSerial.isEmpty {
                    game.romSerial = romSerial
                }
            }
        } catch {
            ELOG("Failed to update game \(game.title) : \(error.localizedDescription)")
        }
     }
    
    public func searchDatabase(usingKey key: String, value: String, systemID: String) throws -> [[String: NSObject]]? {
        
        var openVGDB = self.openVGDB
        if openVGDB == nil {
            do {
                openVGDB = try OESQLiteDatabase(url: Bundle.main.url(forResource: "openvgdb", withExtension: "sqlite")!)
                self.openVGDB = openVGDB
            } catch {
                ELOG("Unable to open game database: \(error.localizedDescription)")
                throw error
            }
        }
        
        var results: [Any]? = nil
        let exactQuery = "SELECT DISTINCT releaseTitleName as 'gameTitle', releaseCoverFront as 'boxImageURL', TEMPRomRegion as 'region', releaseDescription as 'gameDescription', releaseCoverBack as 'boxBackURL', releaseDeveloper as 'developer', releasePublisher as 'publiser', romSerial as 'serial', releaseDate as 'year', releaseGenre as 'genres', releaseReferenceURL as 'referenceURL', releaseID as 'releaseID', TEMPsystemShortName as 'systemShortName' FROM ROMs rom LEFT JOIN RELEASES release USING (romID) WHERE %@ = '%@'"
        let likeQuery = "SELECT DISTINCT romFileName, releaseTitleName as 'gameTitle', releaseCoverFront as 'boxImageURL', TEMPRomRegion as 'region', releaseDescription as 'gameDescription', releaseCoverBack as 'boxBackURL', releaseDeveloper as 'developer', releasePublisher as 'publiser', romSerial as 'serial', releaseDate as 'year', releaseGenre as 'genres', releaseReferenceURL as 'referenceURL', releaseID as 'releaseID', systemShortName FROM ROMs rom LEFT JOIN RELEASES release USING (romID) LEFT JOIN SYSTEMS system USING (systemID) LEFT JOIN REGIONS region on (regionLocalizedID=region.regionID) WHERE %@ LIKE \"%%%@%%\" AND systemID=\"%@\" ORDER BY case when %@ LIKE \"%@%%\" then 1 else 0 end DESC"
        
        let dbSystemID: String = PVEmulatorConfiguration.databaseID(forSystemID: systemID)!
        
        let queryString: String
        if key == "romFileName" {
            queryString = String(format: likeQuery, key, value, dbSystemID, key, value)
        }
        else {
            queryString = String(format: exactQuery, key, value)
        }
        
        do {
            results = try openVGDB!.executeQuery(queryString)
        } catch {
            ELOG("Failed to execute query: \(error.localizedDescription)")
            throw error
        }
        
        return results as? [[String: NSObject]]
    }
    
    static var charset : CharacterSet = {
        var c = CharacterSet.punctuationCharacters
        c.remove(charactersIn: "-+&.'")
        return c
    }()
}

// MARK: - Movers
extension PVGameImporter {
    /**
        Looks at a canidate file (should be a cue). Tries to find .bin files that match the filename by pattern
        matching the filename up to the .cue to other files in the same directory.
     
     - paramater canidateFile: ImportCanidateFile of the .cue file for the CD based rom
     
     - returns: Returns the paths of the .bins and .cue in the new directory they were moved to. Should be a system diretory. Returns nil if a match wasn't found or an error in the process
     */
    func moveCDROM(toAppropriateSubfolder canidateFile: ImportCanidateFile) -> [URL]? {
        
        guard let systemsForExtension = systemIDsForRom(at: canidateFile.filePath) else {
            WLOG("No sytem found for import canidate file \(canidateFile.filePath.lastPathComponent)")
            return nil
        }
        
        var subfolderPathMaybe: String? = nil
        
        var matchedSystemID : String?
        
        if systemsForExtension.count > 1 {
            // Try to match by MD5 or filename
            if let systemID = self.systemId(forROMCanidate: canidateFile) {
                subfolderPathMaybe = systemToPathMap[systemID]
                matchedSystemID = systemID
            } else {
                ILOG("No MD5 match.")
                // No MD5 match, so move to conflict dir
                subfolderPathMaybe = self.conflictPath.path
                self.encounteredConflicts = true
            }
        } else {
            if let onlySystemID = systemsForExtension.first {
                subfolderPathMaybe = systemToPathMap[onlySystemID]
                matchedSystemID = onlySystemID
            }
        }
        
        guard let subfolderPath = subfolderPathMaybe else {
            DLOG("subfolderPathMaybe is nil")
            return nil
        }

        // Create the subfulder path if need be
        do {
            try FileManager.default.createDirectory(atPath: subfolderPath, withIntermediateDirectories: true, attributes: nil)
        } catch {
            ELOG("Unable to create \(subfolderPath) - \(error.localizedDescription)")
            return nil
        }
        
        let newDirectory = URL(fileURLWithPath: subfolderPath, isDirectory:true)
        let newCueSheetPath = newDirectory.appendingPathComponent(canidateFile.filePath.lastPathComponent)
        
        // Try to move the CD file
        do {
            try FileManager.default.moveItem(at: canidateFile.filePath, to: newCueSheetPath)
            ILOG("Moving item \(canidateFile.filePath.path) to \(newCueSheetPath.path)")
        } catch {
            ELOG("Unable move CD file to create \(canidateFile.filePath) - \(error.localizedDescription)")
            return nil
        }

        // Move the cue sheet
        if !encounteredConflicts, let systemID = matchedSystemID {
            // Import to DataBase
            importToDatabaseROM(atPath: newCueSheetPath, systemID: systemID)
        } // else there was a conflict, nothing to import
        
        // moved the .cue, now move .bins .imgs etc to the destination dir (conflicts or system dir, decided above)
        if var paths = moveFiles(similiarToFile: canidateFile.filePath, toDirectory: newDirectory, cuesheet: newCueSheetPath) {
            paths.append(newCueSheetPath)
            return paths
        } else {
            return nil
        }
    }
    
    // TODO: Mabye this should throw
    @discardableResult
    private func importToDatabaseROM(atPath path : URL, systemID: String) -> PVGame? {
        let database = RomDatabase.sharedInstance
        
        let filename = path.lastPathComponent
        let title: String = path.deletingPathExtension().lastPathComponent
        let partialPath: String = URL(fileURLWithPath: systemID, isDirectory: true).appendingPathComponent(filename).path
        
        let game = PVGame()
        game.romPath = partialPath
        game.title = title
        game.systemIdentifier = systemID
        game.requiresSync = true
        
        guard let md5 = calculateMD5(forGame: game) else {
            ELOG("Couldn't calculate MD5 for game \(partialPath)")
            return nil
        }
        
        game.md5Hash = md5
        
        do {
            try database.add(object: game)
        } catch {
            ELOG("Couldn't add new game \(title): \(error.localizedDescription)")
            return nil
        }
        
        finishUpdateOrImport(ofGame: game)
        return game
    }
    
    private func finishUpdateOrImport(ofGame game: PVGame) {
        var modified = false
        
        if game.requiresSync {
            if self.importStartedHandler != nil {
                let fullpath = PVEmulatorConfiguration.path(forGame: game)
                DispatchQueue.main.async(execute: {() -> Void in
                    self.importStartedHandler?(fullpath.path)
                })
            }
            lookupInfo(for: game)
            modified = true
        }
        
        if self.finishedImportHandler != nil {
            let md5: String = game.md5Hash
            DispatchQueue.main.async(execute: {() -> Void in
                self.finishedImportHandler?(md5, modified)
            })
        }
        getArtworkFromURL(game.originalArtworkURL)
    }
    
    func biosEntryMatcing(canidateFile: ImportCanidateFile) -> BIOSEntry? {
        // Check if BIOS by filename - should possibly just only check MD5?
        if let bios = PVEmulatorConfiguration.biosEntry(forFilename: canidateFile.filePath.lastPathComponent) {
            return bios
        } else {
            // Now check by MD5 - md5 is a lazy load var
            if let fileMD5 = canidateFile.md5, let bios = PVEmulatorConfiguration.biosEntry(forMD5: fileMD5) {
                return bios
            }
        }
            
        return nil
    }
    
    func moveROM(toAppropriateSubfolder canidateFile: ImportCanidateFile) -> URL? {
        
        let filePath = canidateFile.filePath
        var newPath: URL? = nil
        var subfolderPathMaybe: URL? = nil

        var systemID: String? = nil
        let fm = FileManager.default
        
        
        // Check if zip
        if PVEmulatorConfiguration.archiveExtensions.contains(filePath.pathExtension) {
            return nil
        }
        
        // Check first if known BIOS
        
        if let biosEntry = biosEntryMatcing(canidateFile: canidateFile) {
            // We have a BIOS file match
            let biosDirectory = PVEmulatorConfiguration.biosPath(forSystemIdentifier: biosEntry.systemID)
            let destiaionPath = biosDirectory.appendingPathComponent(biosEntry.filename, isDirectory:false)
            
            do {
                try fm.createDirectory(at: biosDirectory, withIntermediateDirectories: true, attributes: nil)
                ILOG("Created BIOS directory \(biosDirectory)")
            } catch {
                ELOG("Unable to create BIOS directory \(biosDirectory), \(error.localizedDescription)")
                return nil
            }
            
            do {
                if fm.fileExists(atPath: destiaionPath.path) {
                    ILOG("BIOS already at \(destiaionPath.path). Will try to delete before moving new file.")
                    try fm.removeItem(at: destiaionPath)
                }
                try fm.moveItem(at: filePath, to: destiaionPath)
            } catch {
                ELOG("Unable to move BIOS \(filePath.path) to \(destiaionPath.path) : \(error.localizedDescription)")
            }
            
            return nil
        }
        
        // Done dealing with BIOS file matches
        
        guard let systemsForExtension = systemIDsForRom(at: filePath), !systemsForExtension.isEmpty else {
            ELOG("No system found to match \(filePath.lastPathComponent)")
            return nil
        }

        if systemsForExtension.count > 1, let fileMD5 = canidateFile.md5?.uppercased() {
            // Multiple hits - Check by MD5
            var foundSystemIDMaybe : String?
            
            // Any results of MD5 match?
            var results:  [[String: NSObject]]?
            for currentSystem: String in systemsForExtension {
                // TODO: Would be better performance to search EVERY system MD5 in a single query?
                if let gotit = try? self.searchDatabase(usingKey: "romHashMD5", value: fileMD5, systemID: currentSystem) {
                    foundSystemIDMaybe = currentSystem
                    results = gotit
                    break
                }
            }

            if let results = results, !results.isEmpty {
                
                // We have a valid result, use the ID we found
                systemID = foundSystemIDMaybe
                
                if let s = systemID, let f = systemToPathMap[s] {
                    subfolderPathMaybe = URL.init(fileURLWithPath: f, isDirectory: true)
                } else {
                    ELOG("Didn't expecte any nils here")
                    return nil
                }
            } else {
                // No matches - choose the conflicts folder to move to
                subfolderPathMaybe = self.conflictPath
                self.encounteredConflicts = true
            }
        } else {
            guard let onlySystem = systemsForExtension.first else {
                ILOG("Empty results")
                return nil
            }
            
            // Only 1 result
            systemID = String(onlySystem)
            
            if let s = systemID, let f = systemToPathMap[s] {
                subfolderPathMaybe = URL.init(fileURLWithPath: f, isDirectory: true)
            } else {
                ELOG("Didn't expecte any nils here")
                return nil
            }
        }

        guard let subfolderPath = subfolderPathMaybe, !subfolderPath.path.isEmpty else {
            return nil
        }

        // Try to create the directory where this ROM  goes,
        // withIntermediateDirectories == true means it won't error if exists
        do {
            try fm.createDirectory(at: subfolderPath, withIntermediateDirectories: true, attributes: nil)
        } catch {
            DLOG("Unable to create \(subfolderPath.path) - \(error.localizedDescription)")
            return nil
        }

        let destination = subfolderPath.appendingPathComponent(filePath.lastPathComponent)

        // Try to move the filel to it's home
        do {
            try fm.moveItem(at: filePath, to: destination)
            ILOG("Moved file \(filePath.path) to directory \(destination.path)")
        } catch {

            ELOG("Unable to move file from \(filePath) to \(subfolderPath) - \(error.localizedDescription)")

            switch error {
            case CocoaError.fileWriteFileExists:
                ILOG("File already exists, Deleing from import folder to prevent recursive attempts to move")
                do {
                    try fm.removeItem(at: filePath)
                } catch {
                    ELOG("Unable to delete \(filePath.path) (after trying to move and getting 'file exists error', because \(error.localizedDescription)")
                }
            default:
                break
            }

            return nil
        }

        // We moved sucessfully
        if !self.encounteredConflicts {
            newPath = destination
        }
        return newPath
    }
    
    func moveFiles(similiarToFile inputFile: URL, toDirectory: URL, cuesheet cueSheetPath: URL) -> [URL]? {
        ILOG("Move files files similiar to \(inputFile.path) to directory \(toDirectory.path) from cue sheet \(cueSheetPath.path)")
        let relatedFileName: String = inputFile.deletingPathExtension().lastPathComponent
        
        let contents : [URL]
        let fromDirectory = inputFile.deletingLastPathComponent()
        do {
            contents = try FileManager.default.contentsOfDirectory(at: fromDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles,.skipsPackageDescendants])
        } catch {
            ELOG("Error scanning \(fromDirectory.path), \(error.localizedDescription)")
            return nil
        }
        
        var filesMovedToPaths = [URL]()
        contents.forEach { file in
            var filenameWithoutExtension = file.deletingPathExtension().lastPathComponent
            
            // Some cue's have multiple bins, like, Game.cue Game (Track 1).bin, Game (Track 2).bin ....
            // Clip down the file name to the length of the .cue to see if they start to match
            if filenameWithoutExtension.count > relatedFileName.count {
                filenameWithoutExtension = (filenameWithoutExtension as NSString).substring(with: NSRange(location: 0, length: relatedFileName.count))
                    // RegEx pattern match the parentheses e.g. " (Disc 1)"
                filenameWithoutExtension = filenameWithoutExtension.replacingOccurrences(of: "\\ \\(Disc.*\\)", with: "", options: .regularExpression)
            }
            
            if filenameWithoutExtension == relatedFileName {
                // Before moving the file, make sure the cue sheet's reference uses the same case.
                if !cueSheetPath.path.isEmpty {
                    do {
                        var cuesheet = try String(contentsOf: cueSheetPath)
                        cuesheet = cuesheet.replacingOccurrences(of: filenameWithoutExtension, with: filenameWithoutExtension, options: .caseInsensitive, range: nil)
                        
                        do {
                            try cuesheet.write(to: cueSheetPath, atomically: false, encoding: .utf8)
                        } catch {
                            ELOG("Unable to rewrite cuesheet \(cueSheetPath.path) because \(error.localizedDescription)")
                        }

                    } catch {
                        ELOG("Unable to read cue sheet \(cueSheetPath.path) because \(error.localizedDescription)")
                    }
                }
                
                if !FileManager.default.fileExists(atPath: file.path) {
                    ELOG("Source file \(file.path) doesn't exist!")
                    return
                }
                
                let toPath = toDirectory.appendingPathComponent(file.lastPathComponent, isDirectory: false)
                
                do {
                    try FileManager.default.createDirectory(at: toDirectory, withIntermediateDirectories: true, attributes: nil)
                    try FileManager.default.moveItem(at: file, to: toPath)
                    DLOG("Moved file from \(file) to \(toDirectory.path)")
                    filesMovedToPaths.append(toPath)
                } catch {
                    ELOG("Unable to move file from \(file.path) to \(toPath.path) - \(error.localizedDescription)")
                }
            }
        }
        
        return filesMovedToPaths.isEmpty ? nil : filesMovedToPaths
    }
    
    // Helper
    func systemId(forROMCanidate rom: ImportCanidateFile) -> String? {
        guard let md5 = rom.md5 else {
            ELOG("MD5 was blank")
            return nil
        }
        
        let fileName: String = rom.filePath.lastPathComponent
        let queryString = "SELECT DISTINCT systemID FROM ROMs WHERE romHashMD5 = '\(md5)' OR romFileName = '\(fileName)'"
        
        do {
            // var results: [[String: NSObject]]? = nil
            if let results = try openVGDB?.executeQuery(queryString), let match = results.first, let databaseID = match["systemID"]?.description, let systemID = PVEmulatorConfiguration.systemID(forDatabaseID: databaseID) {
                return systemID
            } else {
                ILOG("Could't match \(rom.filePath.lastPathComponent) based off of MD5 {md5}")
                return nil
            }
        } catch {
            DLOG("Unable to find rom by MD5: \(error.localizedDescription)")
            return nil
        }
    }
}

// The complete but error filled auto-transition is below. Going to pick out parts to use as category extension for now
/*
import Foundation

typealias PVGameImporterImportStartedHandler = (_ path: String) -> Void
typealias PVGameImporterCompletionHandler = (_ encounteredConflicts: Bool) -> Void
typealias PVGameImporterFinishedImportingGameHandler = (_ md5Hash: String, _ modified: Bool) -> Void
typealias PVGameImporterFinishedGettingArtworkHandler = (_ artworkURL: String) -> Void

class PVGameImporter: NSObject {
    private(set) var serialImportQueue: DispatchQueue?
    var importStartedHandler: PVGameImporterImportStartedHandler?
    var completionHandler: PVGameImporterCompletionHandler?
    var finishedImportHandler: PVGameImporterFinishedImportingGameHandler?
    var finishedArtworkHandler: PVGameImporterFinishedGettingArtworkHandler?
    var isEncounteredConflicts = false

    var serialImportQueue: DispatchQueue?
    var systemToPathMap = [AnyHashable: Any]()
    var romExtensionToSystemsMap = [AnyHashable: Any]()
    private var _openVGDB: OESQLiteDatabase?
    var openVGDB: OESQLiteDatabase? {
        if _openVGDB == nil {
                var error: Error?
                _openVGDB = try? OESQLiteDatabase(url: Bundle.main.url(forResource: "openvgdb", withExtension: "sqlite"))
                if _openVGDB == nil {
                    DLog("Unable to open game database: %@", error?.localizedDescription)
                    return nil
                }
            }
            return _openVGDB
    }

    convenience init(completionHandler: PVGameImporterCompletionHandler) {
        self.init()

        self.completionHandler = completionHandler
    
    }

    func conflictedFiles() -> [Any] {
        var error: Error? = nil
        let contents = try? FileManager.default.contentsOfDirectory(atPath: conflictPath())
        if contents == nil {
            DLog("Unable to get contents of %@ because %@", conflictPath(), error?.localizedDescription)
        }
        return contents ?? [Any]()
    }

    func resolveConflicts(withSolutions solutions: [AnyHashable: Any]) {
        let filePaths = solutions.keys
        for filePath: String in filePaths {
            let systemID = solutions[filePath] as? String
            let subfolder = systemToPathMap[systemID] as? String
            if !FileManager.default.fileExists(atPath: subfolder) {
                try? FileManager.default.createDirectory(atPath: subfolder, withIntermediateDirectories: true, attributes: nil)
            }
            var error: Error? = nil
            if (try? FileManager.default.moveItem(atPath: URL(fileURLWithPath: conflictPath()).appendingPathComponent(filePath).path, toPath: URL(fileURLWithPath: subfolder).appendingPathComponent(filePath).path)) == nil {
                DLog("Unable to move %@ to %@ because %@", filePath, subfolder, error?.localizedDescription)
            }
                // moved the .cue, now move .bins .imgs etc
            let cueSheetPath: String = URL(fileURLWithPath: subfolder).appendingPathComponent(filePath).path
            let relatedFileName: String = URL(fileURLWithPath: filePath).deletingPathExtension().path
            let contents = try? FileManager.default.contentsOfDirectory(atPath: conflictPath())
            for file: String in contents {
                    // Crop out any extra info in the .bin files, like Game.cue and Game (Track 1).bin, we want to match up to just 'Game'
                var fileWithoutExtension: String = file.replacingOccurrences(of: ".\(URL(fileURLWithPath: file).pathExtension)", with: "")
                if fileWithoutExtension.count > relatedFileName.count {
                    fileWithoutExtension = (fileWithoutExtension as NSString).substring(with: NSRange(location: 0, length: relatedFileName.count))
                }
                if fileWithoutExtension == relatedFileName {
                        // Before moving the file, make sure the cue sheet's reference uses the same case.
                    var cuesheet = try? String(contentsOfFile: cueSheetPath, encoding: .utf8)
                    if cuesheet != nil {
                        let range: NSRange? = (cuesheet as NSString?)?.range(of: file, options: .caseInsensitive)
                        if range?.location != NSNotFound {
                            if let subRange = Range<String.Index>(range ?? NSRange(), in: cuesheet) { cuesheet?.replaceSubrange(subRange, with: file) }
                            if (try? cuesheet?.write(toFile: cueSheetPath, atomically: false, encoding: .utf8)) == nil {
                                DLog("Unable to rewrite cuesheet %@ because %@", cueSheetPath, error?.localizedDescription)
                            }
                        }
                        else {
                            DLog("Range of string <%@> not found in file <%@>", file, cueSheetPath)
                        }
                    }
                    else {
                        DLog("Unable to read cue sheet %@ because %@", cueSheetPath, error?.localizedDescription)
                    }
                    if (try? FileManager.default.moveItem(atPath: URL(fileURLWithPath: conflictPath()).appendingPathComponent(file).path, toPath: URL(fileURLWithPath: subfolder).appendingPathComponent(file).path)) == nil {
                        DLog("Unable to move file from %@ to %@ - %@", filePath, subfolder, error?.localizedDescription)
                    }
                }
            }
            weak var weakSelf: PVGameImporter? = self
            serialImportQueue.async(execute: {() -> Void in
                weakSelf?.getRomInfoForFiles(atPaths: [filePath], userChosenSystem: systemID)
                if weakSelf?.self.completionHandler != nil {
                    DispatchQueue.main.async(execute: {() -> Void in
                        weakSelf?.self.completionHandler(false)
                    })
                }
            })
        }
    }

    func getRomInfoForFiles(atPaths paths: [Any], userChosenSystem systemID: String) {
        let database = RomDatabase.sharedInstance
        database.refresh()
        for path: String in paths {
            let isDirectory: Bool = !path.contains(".")
            if path.hasPrefix(".") || isDirectory {
                continue
            }
            autoreleasepool {
                var systemID: String? = nil
                if chosenSystemID.count == 0 {
                    systemID = PVEmulatorConfiguration.systemIdentifier(forFileExtension: URL(fileURLWithPath: path).pathExtension)
                }
                else {
                    systemID = chosenSystemID
                }
                let cdBasedSystems = PVEmulatorConfiguration.cdBasedSystemIDs()
                if cdBasedSystems.contains(systemID ?? "") && ((URL(fileURLWithPath: path).pathExtension == "cue") == false) {
                    continue
                }
                let partialPath: String = URL(fileURLWithPath: systemID ?? "").appendingPathComponent(path.lastPathComponent).path
                let title: String = path.lastPathComponent.replacingOccurrences(of: "." + (URL(fileURLWithPath: path).pathExtension), with: "")
                var game: PVGame? = nil
                let results: RLMResults? = database.objectsOf(PVGame.self, predicate: NSPredicate(format: "romPath == %@", partialPath.count ? partialPath : ""))
                if results?.count() != nil {
                    game = results?.first
                }
                else {
                    if systemID?.count == nil {
                        continue
                    }
                    game = PVGame()
                    game?.romPath = partialPath
                    game?.title = title
                    game?.systemIdentifier = systemID
                    game?.isRequiresSync = true
                    try? database.add(withObject: game)
                }
                var modified = false
                if game?.requiresSync() != nil {
                    if importStartedHandler {
                        DispatchQueue.main.async(execute: {() -> Void in
                            self.importStartedHandler(path)
                        })
                    }
                    lookupInfo(for: game)
                    modified = true
                }
                if finishedImportHandler {
                    let md5: String? = game?.md5Hash()
                    DispatchQueue.main.async(execute: {() -> Void in
                        self.finishedImportHandler(md5, modified)
                    })
                }
                getArtworkFromURL(game?.originalArtworkURL())
            }
        }
    }

    func getArtworkFromURL(_ url: String) {
        if !url.count || PVMediaCache.filePath(forKey: url).length() {
            return
        }
        DLog("Starting Artwork download for %@", url)
        let artworkURL = URL(string: url)
        if artworkURL == nil {
            return
        }
        let request = URLRequest(url: artworkURL!)
        var urlResponse: HTTPURLResponse? = nil
        var error: Error? = nil
        let data: Data? = try? PVSynchronousURLSession.sendSynchronousRequest(request, returning: urlResponse)
        if error != nil {
            DLog("error downloading artwork from: %@ -- %@", url, error?.localizedDescription)
            return
        }
        if urlResponse?.statusCode != 200 {
            DLog("HTTP Error: %zd", urlResponse?.statusCode)
            DLog("Response: %@", urlResponse)
        }
        let artwork = UIImage(data: data ?? Data())
        if artwork != nil {
            PVMediaCache.writeImage(toDisk: artwork, withKey: url)
        }
        if finishedArtworkHandler {
            DispatchQueue.main.sync(execute: {() -> Void in
                self.finishedArtworkHandler(url)
            })
        }
    }

// MARK: -

    override init() {
        super.init()
        
        serialImportQueue = DispatchQueue(label: "com.jamsoftonline.provenance.serialImportQueue")
        systemToPathMap = updateSystemToPathMap()
        romExtensionToSystemsMap = updateromExtensionToSystemsMap()
    
    }

// MARK: - ROM Lookup

    func lookupInfo(for game: PVGame) {
        RomDatabase.sharedInstance.refresh()
        if !game.md5Hash().length() {
            var offset: Int = 0
            if (game.systemIdentifier() == PVNESSystemIdentifier) {
                offset = 16
                // make this better
            }
            let md5Hash: String = FileManager.default.md5ForFile(atPath: URL(fileURLWithPath: documentsPath()).appendingPathComponent(game.romPath()).path, fromOffset: offset)
            RomDatabase.sharedInstance.writeTransactionAndReturnError(nil, {() -> Void in
                game.md5Hash = md5Hash
            })
        }
        var error: Error? = nil
        var results: [Any]? = nil
        if game.md5Hash().length() {
            results = try? self.searchDatabase(usingKey: "romHashMD5", value: game.md5Hash().uppercased(), systemID: game.systemIdentifier())
        }
        if results?.count == nil {
            var fileName: String = game.romPath().lastPathComponent
                // Remove any extraneous stuff in the rom name such as (U), (J), [T+Eng] etc
            var charSet: CharacterSet? = nil
            var onceToken: Int
            if (onceToken == 0) {
            /* TODO: move below code to a static variable initializer (dispatch_once is deprecated) */
                charSet = CharacterSet.punctuationCharacters
                charSet?.removeCharacters(in: "-+&.'")
            }
        onceToken = 1
            let nonCharRange: NSRange = (fileName as NSString).rangeOfCharacter(from: charSet!)
            var gameTitleLen: Int
            if nonCharRange.length > 0 && nonCharRange.location > 1 {
                gameTitleLen = nonCharRange.location - 1
            }
            else {
                gameTitleLen = fileName.count
            }
            fileName = ((fileName as? NSString)?.substring(to: gameTitleLen)) ?? ""
            results = try? self.searchDatabase(usingKey: "romFileName", value: fileName, systemID: game.systemIdentifier())
        }
        if results?.count == nil {
            DLog("Unable to find ROM (%@) in DB", game.romPath())
            RomDatabase.sharedInstance.writeTransactionAndReturnError(nil, {() -> Void in
                game.isRequiresSync = false
            })
            return
        }
        var chosenResult: [AnyHashable: Any]? = nil
        for result: [AnyHashable: Any] in results {
            if (result["region"] == "USA") {
                chosenResult = result
                break
            }
        }
        if chosenResult == nil {
            chosenResult = results?.first
        }
        RomDatabase.sharedInstance.writeTransactionAndReturnError(nil, {() -> Void in
            game.isRequiresSync = false
            if chosenResult["gameTitle"].length() {
                game.title = chosenResult["gameTitle"]
            }
            if chosenResult["boxImageURL"].length() {
                game.originalArtworkURL = chosenResult["boxImageURL"]
            }
        })
    }

    func searchDatabase(usingKey key: String, value: String, systemID: String) throws -> [Any] {
        if openVGDB == nil {
            openVGDB = try? OESQLiteDatabase(url: Bundle.main.url(forResource: "openvgdb", withExtension: "sqlite"))
        }
        if openVGDB == nil {
            DLog("Unable to open game database: %@", error?.localizedDescription)
            return nil
        }
        var results: [Any]? = nil
        let exactQuery = "SELECT DISTINCT releaseTitleName as 'gameTitle', releaseCoverFront as 'boxImageURL' FROM ROMs rom LEFT JOIN RELEASES release USING (romID) WHERE %@ = '%@'"
        let likeQuery = "SELECT DISTINCT romFileName, releaseTitleName as 'gameTitle', releaseCoverFront as 'boxImageURL', regionName as 'region', systemShortName FROM ROMs rom LEFT JOIN RELEASES release USING (romID) LEFT JOIN SYSTEMS system USING (systemID) LEFT JOIN REGIONS region on (regionLocalizedID=region.regionID) WHERE %@ LIKE \"%%%@%%\" AND systemID=\"%@\" ORDER BY case when %@ LIKE \"%@%%\" then 1 else 0 end DESC"
        var queryString: String? = nil
        let dbSystemID: String = PVEmulatorConfiguration.databaseID(forSystemID: systemID)
        if (key == "romFileName") {
            queryString = String(format: likeQuery, key, value, dbSystemID, key, value)
        }
        else {
            queryString = String(format: exactQuery, key, value)
        }
        results = try? openVGDB?.executeQuery(queryString)
        return results ?? [Any]()
    }
}

extension NSArray {
    func mapObjects(usingBlock block: @escaping (_ obj: Any, _ idx: Int) -> Any) -> [Any] {
        var result = [AnyHashable]() /* TODO: .reserveCapacity(count) */
        (self as NSArray).enumerateObjects({(_ obj: Any, _ idx: Int, _ stop: Bool) -> Void in
            result.append(block(obj, idx))
        })
        return result
    }
}
 
*/