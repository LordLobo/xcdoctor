//
//  XcodeProject.swift
//  xcdoctor
//
//  Created by Jacob Hauberg Hansen on 26/06/2020.
//  Copyright © 2020 Jacob Hauberg Hansen. All rights reserved.
//

import Foundation

// a mapping of `lastKnownFileType` and its common extensions
// note that files matching these indicators will be subject
// to full-text search (unusedResources), so including assets
// (e.g. images, or videos, in particular) would not be ideal
let sourceTypes: [(String, [String])] = [
    ("file.storyboard", ["storyboard"]),
    ("file.xib", ["xib", "nib"]),
    ("folder.assetcatalog", ["xcassets"]),
    ("text.plist.strings", ["strings"]),
    ("text.plist.xml", ["plist"]),
    ("sourcecode.c.c", ["c"]),
    ("sourcecode.c.h", ["h", "pch"]),
    ("sourcecode.c.objc", ["m"]),
    ("sourcecode.cpp.objcpp", ["mm"]),
    ("sourcecode.cpp.cpp", ["cpp", "cc"]),
    ("sourcecode.cpp.h", ["h", "hh"]),
    ("sourcecode.swift", ["swift"]),
    ("sourcecode.metal", ["metal", "mtl"]),
    ("text.script.sh", ["sh"]),
]

// represents any object in a pbxproj file; it's essentially just a key (id) and a dict
private struct PBXObject {
    let id: String
    let properties: [String: Any]
}

struct GroupReference {
    let url: URL?
    let projectUrl: URL // TODO: naming, this is the visual tree as seen in Xcode
    let name: String
    let hasChildren: Bool

    var path: String? {
        url?.standardized.relativePath
    }
}

struct FileReference {
    let url: URL
    // TODO: could add visual/project url here as well to help locating a non-existent file in project
    let kind: String?
    let hasTargetMembership: Bool

    var path: String {
        url.standardized.relativePath
    }

    var isSourceFile: Bool {
        sourceTypes.contains { (fileType, extensions) -> Bool in
            kind == fileType || extensions.contains(url.pathExtension)
        }
    }

    var isHeaderFile: Bool {
        // TODO: should have some way of checking against sourceTypes instead of repeating
        //       for example, a file like prefix.pch would not be considered a headerfile
        //       - but does have kind "sourcecode.c.h"
        url.pathExtension == "h" || url.pathExtension == "hh" || url.pathExtension == "pch"
    }
}

struct ProductReference {
    let name: String
    let buildsSourceFiles: Bool
}

public enum XcodeProjectError: Error, Equatable {
    case incompatible(reason: String)
    case notFound(amongFilesInDirectory: Bool) // param indicates whether directory was searched
}

private struct XcodeProjectLocation {
    let root: URL // directory containing .xcodeproj
    let xcodeproj: URL // path to .xcodeproj
    let pbx: URL // path to .xcodeproj/project.pbxproj
}

private func findProjectLocation(from url: URL) -> Result<XcodeProjectLocation, XcodeProjectError> {
    let xcodeprojUrl: URL
    if !FileManager.default.fileExists(atPath: url.standardized.path) {
        return .failure(.notFound(amongFilesInDirectory: url.hasDirectoryPath))
    }
    if !url.isDirectory {
        return .failure(.incompatible(reason: "not an Xcode project"))
    }
    if url.pathExtension != "xcodeproj" {
        let files = try! FileManager.default.contentsOfDirectory(
            atPath: url.standardized.path
        )
        if let xcodeProjectFile = files.first(where: { file -> Bool in
            file.hasSuffix("xcodeproj")
        }) {
            xcodeprojUrl = url.appendingPathComponent(xcodeProjectFile)
        } else {
            return .failure(.notFound(amongFilesInDirectory: true))
        }
    } else {
        xcodeprojUrl = url
    }
    let pbxUrl = xcodeprojUrl.appendingPathComponent("project.pbxproj")
    if !FileManager.default.fileExists(atPath: pbxUrl.standardized.path) {
        return .failure(.incompatible(reason: "unsupported Xcode project format"))
    }
    let directoryUrl = xcodeprojUrl // for example, ~/Development/My/Project.xcodeproj
        .deletingLastPathComponent() //             ~/Development/My/
    return .success(XcodeProjectLocation(root: directoryUrl, xcodeproj: xcodeprojUrl, pbx: pbxUrl))
}

public struct XcodeProject {
    /**
     Attempts to locate and read an Xcode project at a given URL.

     If the URL leads to a directory, files in that directory will be enumerated in search
     of an .xcodeproj (subdirectories will not be searched).
     */
    public static func open(from url: URL) -> Result<XcodeProject, XcodeProjectError> {
        let projectLocation: XcodeProjectLocation
        switch findProjectLocation(from: url) {
        case let .success(location):
            projectLocation = location
        case let .failure(error):
            return .failure(error)
        }
        do {
            var format = PropertyListSerialization.PropertyListFormat.openStep
            guard let plist = try PropertyListSerialization.propertyList(
                from: try Data(contentsOf: projectLocation.pbx),
                options: .mutableContainersAndLeaves,
                format: &format
            ) as? [String: Any] else {
                return .failure(.incompatible(reason: "unsupported Xcode project format"))
            }
            return .success(
                XcodeProject(locatedAt: projectLocation, objectGraph: plist))
        } catch {
            return .failure(.incompatible(reason: "unsupported Xcode project format"))
        }
    }

    private init(locatedAt location: XcodeProjectLocation, objectGraph: [String: Any]) {
        self.location = location
        propertyList = objectGraph
        resolve()
    }

    private let location: XcodeProjectLocation

    // TODO: rename simply as File, Group, Product?
    private var fileRefs: [FileReference] = []
    private var groupRefs: [GroupReference] = []
    private var productRefs: [ProductReference] = []

    private let propertyList: [String: Any]
    private var buildConfigObjects: [PBXObject] = []

    var files: [FileReference] {
        fileRefs
    }

    var groups: [GroupReference] {
        groupRefs
    }

    var products: [ProductReference] {
        productRefs
    }

    private mutating func resolve() {
        // TODO: refactor this bit; essentially all done during initialization: lazy vars?
        fileRefs.removeAll()
        groupRefs.removeAll()
        productRefs.removeAll()
        buildConfigObjects.removeAll()

        let items = objects()

        func objects(identifyingAs isa: [String]) -> [PBXObject] {
            items.filter { object -> Bool in
                if let identity = object.properties["isa"] as? String {
                    return isa.contains(identity)
                }
                return false
            }
        }

        buildConfigObjects = objects(identifyingAs: ["XCBuildConfiguration"])

        let fileItems = objects(identifyingAs: ["PBXFileReference"])
        let groupItems = objects(identifyingAs: ["PBXGroup", "PBXVariantGroup"])
        let nativeTargetItems = objects(identifyingAs: ["PBXNativeTarget"])
        let buildFileReferences = objects(identifyingAs: ["PBXBuildFile"])
            .map { object -> String in
                object.properties["fileRef"] as! String
            }

        let excludedFileTypes = ["wrapper.xcdatamodel"]

        for file in fileItems {
            let potentialFileType = file.properties["lastKnownFileType"] as? String
            let explicitfileType = file.properties["explicitFileType"] as? String
            let fileType = explicitfileType ?? potentialFileType

            if let fileType = fileType, excludedFileTypes.contains(fileType) {
                continue
            }

            guard let fileUrl = resolveFileURL(object: file, groups: groupItems) else {
                continue
            }

            var isReferencedAsBuildFile: Bool = false
            if buildFileReferences.contains(file.id) {
                // file is directly referenced as a build file
                isReferencedAsBuildFile = true
            } else {
                // file might be contained in a parent group that is referenced as a build file
                var ref = file
                while let parent = parent(of: ref, in: groupItems) {
                    if buildFileReferences.contains(parent.id) {
                        isReferencedAsBuildFile = true
                        break
                    }
                    ref = parent
                }
            }
            fileRefs.append(
                FileReference(
                    url: fileUrl,
                    kind: fileType,
                    hasTargetMembership: isReferencedAsBuildFile
                )
            )
        }

        for group in groupItems {
            guard let children = group.properties["children"] as? [String],
                let projectUrl = resolveProjectURL(object: group, groups: groupItems) else {
                continue
            }
            guard let name = group.properties["name"] as? String ??
                group.properties["path"] as? String else {
                continue
            }
            let directoryUrl = resolveFileURL(object: group, groups: groupItems)
            groupRefs.append(
                GroupReference(
                    url: directoryUrl,
                    projectUrl: projectUrl,
                    name: name,
                    hasChildren: !children.isEmpty
                )
            )
        }

        for target in nativeTargetItems {
            guard let name = target.properties["name"] as? String else {
                continue
            }
            var compilesAnySource =
                false // false until we determine any compilation phase of at least one source file
            if let phases = target.properties["buildPhases"] as? [String] {
                let compilationPhases = items.filter { object -> Bool in
                    phases.contains(object.id)
                }.filter { phase -> Bool in
                    if let isa = phase.properties["isa"] as? String {
                        return isa == "PBXSourcesBuildPhase"
                    }
                    return false
                }
                if !compilationPhases.isEmpty {
                    for phase in compilationPhases {
                        if let sources = phase.properties["files"] as? [String], !sources.isEmpty {
                            // target compiles at least one source file
                            compilesAnySource = true
                            break
                        }
                    }
                }
            }
            productRefs.append(
                ProductReference(
                    name: name,
                    buildsSourceFiles: compilesAnySource
                )
            )
        }
    }

    private func resolveProjectURL(object: PBXObject, groups: [PBXObject]) -> URL? {
        guard var path = object.properties["name"] as? String ?? object
            .properties["path"] as? String else {
            return nil
        }

        var ref = object
        while let parent = parent(of: ref, in: groups) {
            if let parentPath = parent.properties["name"] as? String ?? parent
                .properties["path"] as? String,
                !parentPath.isEmpty {
                path = "\(parentPath)/\(path)"
            }
            ref = parent
        }

        return URL(string: path)
    }

    private func resolveFileURL(object: PBXObject, groups: [PBXObject]) -> URL? {
        guard let sourceTree = object.properties["sourceTree"] as? String,
            var path = object.properties["path"] as? String else {
            return nil
        }
        switch sourceTree {
        case "":
            // skip this file
            return nil
        case "SDKROOT":
            // skip this file
            return nil
        case "DEVELOPER_DIR":
            // skip this file
            return nil
        case "BUILT_PRODUCTS_DIR":
            // skip this file
            return nil
        case "SOURCE_ROOT":
            // leave path unchanged
            break
        case "<absolute>":
            // leave path unchanged
            break
        case "<group>":
            var ref = object
            while let parent = parent(of: ref, in: groups) {
                if let parentPath = parent.properties["path"] as? String, !parentPath.isEmpty {
                    path = "\(parentPath)/\(path)"
                    let groupSourceTree = parent.properties["sourceTree"] as! String
                    if groupSourceTree == "SOURCE_ROOT" {
                        // don't resolve further back, even if
                        // this group is a child of another group
                        break
                    }
                } else {
                    // non-folder group or root of hierarchy
                }
                ref = parent
            }
        default:
            fatalError()
        }
        if NSString(string: path).isAbsolutePath {
            return URL(fileURLWithPath: path)
        }
        return location.root.appendingPathComponent(path)
    }

    private func objects() -> [PBXObject] {
        if let objects = propertyList["objects"] as? [String: Any] {
            return objects.map { (key: String, value: Any) -> PBXObject in
                PBXObject(id: key, properties: value as? [String: Any] ?? [:])
            }
        }
        return []
    }

    private func parent(of object: PBXObject, in groups: [PBXObject]) -> PBXObject? {
        groups.filter { parent -> Bool in
            if let children = parent.properties["children"] as? [String] {
                return children.contains(object.id)
            }
            return false
        }.first
    }

    func referencesAssetAsAppIcon(named asset: String) -> Bool {
        for object in buildConfigObjects {
            if let settings = object.properties["buildSettings"] as? [String: Any] {
                if let appIconSetting =
                    settings["ASSETCATALOG_COMPILER_APPICON_NAME"] as? String {
                    if appIconSetting == asset {
                        return true
                    }
                }
            }
        }
        return false
    }

    func referencesPropertyListAsInfoPlist(named file: FileReference) -> Bool {
        for object in buildConfigObjects {
            if let settings = object.properties["buildSettings"] as? [String: Any] {
                if let infoPlistSetting = settings["INFOPLIST_FILE"] as? String {
                    let setting = infoPlistSetting.replacingOccurrences(
                        of: "$(SRCROOT)", with: location.root.standardized.path
                    )
                    if file.url.standardized.path.hasSuffix(setting) {
                        return true
                    }
                }
            }
        }
        return false
    }
}
