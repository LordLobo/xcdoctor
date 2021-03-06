//
//  Diagnose.swift
//  xcdoctor
//
//  Created by Jacob Hauberg Hansen on 26/06/2020.
//  Copyright © 2020 Jacob Hauberg Hansen. All rights reserved.
//

import Foundation

/**
 Represents an undesired condition for an Xcode project.
 */
public enum Defect {
    /**
     A condition that applies if any file reference resolves to a file that does not exist on disk.
     */
    case nonExistentFiles
    /**
     A condition that applies if any property-list (.plist) fails to convert to a
     serialized representation.
     */
    case corruptPropertyLists
    /**
     A condition that applies if any source-file does not have target membership.
     */
    case danglingFiles
    /**
     A condition that applies if any non-source-file (including resources in assetcatalogs)
     does not appear to be used in any source-file.

     Whether or not a resource is deemed to be in use relies on simple pattern matching
     and is prone to both false-positives and missed cases.
     */
    case unusedResources
    /**
     A condition that applies if any groups (including non-folder groups) resolves to
     a path that does not exist on disk.
     */
    case nonExistentPaths
    /**
     A condition that applies if any group contains zero children (files or groups).
     */
    case emptyGroups
    /**
     A condition that applies if any native target is not built from at least one source-file.
     */
    case emptyTargets
}

/**
 Represents a diagnosis of a defect in an Xcode project.
 */
public struct Diagnosis {
    /**
     Represents a conclusive message for the result of this diagnosis.
     */
    public let conclusion: String
    /**
     Represents a helpful message on how to go about dealing with this diagnosis.
     */
    public let help: String?
    /**
     Represents a set of concrete cases that are directly linked to causing this diagnosis.
     */
    public let cases: [String]?
}

private func nonExistentFiles(in project: XcodeProject) -> [FileReference] {
    project.files.filter { ref -> Bool in
        // include this reference if file does not exist
        !FileManager.default.fileExists(atPath: ref.path)
    }
}

private func nonExistentFilePaths(in project: XcodeProject) -> [String] {
    nonExistentFiles(in: project).map { ref -> String in
        ref.path
    }
}

func nonExistentGroups(in project: XcodeProject) -> [GroupReference] {
    project.groups.filter { ref -> Bool in
        if let path = ref.path {
            return !FileManager.default.fileExists(atPath: path)
        }
        return false
    }
}

private func nonExistentGroupPaths(in project: XcodeProject) -> [String] {
    nonExistentGroups(in: project).map { ref -> String in
        "\(ref.path!): \"\(ref.projectUrl.absoluteString)\""
    }
}

private func emptyGroups(in project: XcodeProject) -> [GroupReference] {
    project.groups.filter { ref -> Bool in
        !ref.hasChildren
    }
}

private func emptyGroupPaths(in project: XcodeProject) -> [String] {
    emptyGroups(in: project).map { ref -> String in
        "\(ref.projectUrl.absoluteString)"
    }
}

private func emptyTargetNames(in project: XcodeProject) -> [String] {
    project.products.filter { ref -> Bool in
        !ref.buildsSourceFiles
    }.map { product -> String in
        product.name
    }
}

private func propertyListReferences(in project: XcodeProject) -> [FileReference] {
    project.files.filter { ref -> Bool in
        ref.kind == "text.plist.xml" || ref.url.pathExtension == "plist"
    }
}

private func danglingFilePaths(in project: XcodeProject) -> [String] {
    project.files.filter { ref -> Bool in
        !ref.isHeaderFile && ref.isSourceFile && !ref.hasTargetMembership
    }.filter { ref -> Bool in
        // handle the special-case Info.plist
        if ref.kind == "text.plist.xml" || ref.url.pathExtension == "plist" {
            return !project.referencesPropertyListAsInfoPlist(named: ref)
        }
        return true
    }.map { ref -> String in
        ref.path
    }
}

private func sourceFiles(in project: XcodeProject) -> [FileReference] {
    let exceptFiles = nonExistentFiles(in: project)
    return project.files.filter { ref -> Bool in
        ref.isSourceFile && // file is compiled in one way or another
            !ref.url.isDirectory && // file is text-based; i.e. not a directory
            !exceptFiles.contains(where: { otherRef -> Bool in // file exists
                ref.url == otherRef.url
            })
    }
}

private extension String {
    var removingScaleFactors: String {
        replacingOccurrences(of: "@1x", with: "")
            .replacingOccurrences(of: "@2x", with: "")
            .replacingOccurrences(of: "@3x", with: "")
    }
}

private struct Resource {
    let name: String
    let fileName: String?
    let nameVariants: [String]
    init(name: String, fileName: String? = nil) {
        self.name = name
        self.fileName = fileName
        if let fileName = fileName {
            let plainName = name.removingScaleFactors
            let plainFileName = fileName.removingScaleFactors
            nameVariants = Array(Set([
                name,
                fileName,
                plainName,
                plainFileName,
            ]))
        } else {
            // if a filename has not been set, we can be reasonably certain that
            // this is not a file that has assigned scale factors
            nameVariants = [name]
        }
    }
}

private func resources(in project: XcodeProject) -> [Resource] {
    let sources = sourceFiles(in: project).filter { ref -> Bool in
        // exclude xml/html files as sources; consider them both source and resource
        // TODO: this is a bit of a slippery slope; where do we draw the line?
        //       stuff like JSON and YAML probably fits here as well, etc. etc. ...
        ref.kind != "text.xml" && ref.url.pathExtension != "xml" &&
            ref.kind != "text.html" && ref.url.pathExtension != "html"
    }
    return project.files.filter { ref -> Bool in
        // TODO: specific exclusions? e.g. "archive.ar"/"a", ".whatever" etc
        ref.hasTargetMembership &&
            ref.kind != "folder.assetcatalog" && // not an assetcatalog
            ref.url.pathExtension != "xcassets" && // not an assetcatalog
            ref.kind != "wrapper.framework" && // not a dynamic framework
            ref.url.pathExtension != "a" && // not a static library
            ref.url.pathExtension != "xcconfig" && // not xcconfig
            !ref.url.lastPathComponent.hasPrefix(".") && // not a hidden file
            !sources.contains { sourceRef -> Bool in // not a source-file
                ref.url == sourceRef.url
            }
    }.map { ref -> Resource in
        Resource(name: ref.url.deletingPathExtension().lastPathComponent,
                 fileName: ref.url.lastPathComponent)
    }
}

private extension URL {
    /**
     Return true if the url points to a directory containing a `Contents.json` file.
     */
    var isAssetURL: Bool {
        FileManager.default.fileExists(atPath:
            appendingPathComponent("Contents.json").path)
    }
}

private extension String {
    func removingOccurrences(matchingExpressions expressions: [NSRegularExpression]) -> String {
        var str = self
        for expr in expressions {
            var match = expr.firstMatch(
                in: str,
                range: NSRange(location: 0, length: str.utf16.count)
            )
            while match != nil {
                str.replaceSubrange(Range(match!.range, in: str)!, with: "")
                match = expr.firstMatch(
                    in: str,
                    range: NSRange(location: 0, length: str.utf16.count)
                )
            }
        }
        return str
    }
}

private func assetURLs(at url: URL) -> [URL] {
    guard let dirEnumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.isDirectoryKey]
    ) else {
        return []
    }

    return dirEnumerator.map { item -> URL in
        item as! URL
    }.filter { url -> Bool in
        url.isDirectory && url.isAssetURL && !url.pathExtension.isEmpty
    }
}

private func assets(in project: XcodeProject) -> [Resource] {
    project.files.filter { ref -> Bool in
        ref.kind == "folder.assetcatalog" || ref.url.pathExtension == "xcassets"
    }.flatMap { ref -> [Resource] in
        assetURLs(at: ref.url).map { assetUrl -> Resource in
            Resource(name: assetUrl.deletingPathExtension().lastPathComponent)
        }
    }
}

private final class SourcePatterns {
    static let blockComments =
        try! NSRegularExpression(pattern:
            // note the #..# to designate a raw string, allowing the \* literal
            #"/\*(?:.|[\n])*?\*/"#)
    static let lineComments =
        try! NSRegularExpression(pattern:
            "(?:[^:]|^)" + // avoid matching URLs in code, but anything else goes
                "//" + // starting point of a single-line comment
                ".*?" + // anything following
                "(?:\n|$)", // until reaching end of string or a newline
            options: [.anchorsMatchLines])
    static let htmlComments =
        try! NSRegularExpression(pattern:
            // strip HTML/XML comments
            "<!--.+?-->",
            options: [.dotMatchesLineSeparators])
    static let appFonts = try! NSRegularExpression(pattern:
        // strip this particular and iOS specific plist-entry
        "<key>UIAppFonts</key>.+?</array>",
        options: [.dotMatchesLineSeparators])
}

// TODO: optionally include some info, Any? for printout under DEBUG/verbose
public typealias ExaminationProgressCallback = (Int, Int, String?) -> Void

public func examine(
    project: XcodeProject,
    for defect: Defect,
    progress: ExaminationProgressCallback? = nil
) -> Diagnosis? {
    switch defect {
    case .nonExistentFiles:
        let filePaths = nonExistentFilePaths(in: project)
        if !filePaths.isEmpty {
            return Diagnosis(
                conclusion: "non-existent files",
                help: """
                These files are not present on the file system and could have been moved or removed.
                In either case, each reference should be resolved or removed from the project.
                """,
                cases: filePaths
            )
        }
    case .nonExistentPaths:
        let dirPaths = nonExistentGroupPaths(in: project)
        if !dirPaths.isEmpty {
            return Diagnosis(
                conclusion: "non-existent group paths",
                // TODO: word this differently; a non-existent path is typically harmless:
                //
                //       "This is typically seen in projects under version-control, where a
                //       contributor has this folder on their local copy, but, if empty,
                //       is not added to version-control, leaving other contributors with a group
                //       in Xcode, but no folder on disk to go with it."
                //
                //       however, there's also another case where occurs:
                //       this is similarly harmless (typically), but is objectively a project smell:
                //       if moving things around/messing with project files directly; e.g.
                //       a group is both named and pathed (incorrectly), with child groups
                //       overriding the incorrect path by using SOURCE_ROOT or similar
                //       so ultimately everything works fine in Xcode, even though there is a bad path
                help: """
                If not corrected, these paths can cause tools to erroneously
                map children of each group to non-existent files.
                """,
                cases: dirPaths
            )
        }
    case .corruptPropertyLists:
        let files = propertyListReferences(in: project)
        var corruptedFilePaths: [String] = []
        for (n, file) in files.enumerated() {
            #if DEBUG
                progress?(n + 1, files.count, file.url.lastPathComponent)
            #else
                progress?(n + 1, files.count, nil)
            #endif

            do {
                _ = try PropertyListSerialization.propertyList(
                    from: try Data(contentsOf: file.url),
                    format: nil
                )
            } catch let error as NSError {
                let additionalInfo: String
                if let helpfulErrorMessage = error.userInfo[NSDebugDescriptionErrorKey] as? String {
                    // this is typically along the lines of:
                    //  "Value missing for key inside <dict> at line 7"
                    additionalInfo = helpfulErrorMessage
                } else {
                    // this is typically more like:
                    //  "The data couldn’t be read because it isn’t in the correct format."
                    additionalInfo = error.localizedDescription
                }
                corruptedFilePaths.append("\(file.path): \(additionalInfo)")
            }
        }

        progress?(files.count, files.count, nil)

        if !corruptedFilePaths.isEmpty {
            return Diagnosis(
                conclusion: "corrupted plists",
                help: """
                These files must be fixed manually using any plain-text editor.
                """,
                cases: corruptedFilePaths
            )
        }
    case .danglingFiles:
        let filePaths = danglingFilePaths(in: project)
        if !filePaths.isEmpty {
            return Diagnosis(
                conclusion: "files not included in any target",
                help: """
                These files are never being compiled and might not be used;
                consider whether they should be removed.
                """,
                cases: filePaths
            )
        }
    case .unusedResources:
        var res = resources(in: project) + assets(in: project)
        // find special cases, e.g. AppIcon
        res.removeAll { resource -> Bool in
            for resourceName in resource.nameVariants {
                if project.referencesAssetAsAppIcon(named: resourceName) {
                    // resource seems to be used; remove and don't search further for this
                    return true
                }
            }
            // resource seems to be unused; don't remove and keep searching for usages
            return false
        }
        // full-text search every source-file
        let sources = sourceFiles(in: project)
        for (n, source) in sources.enumerated() {
            #if DEBUG
                progress?(n + 1, sources.count, source.url.lastPathComponent)
            #else
                progress?(n + 1, sources.count, nil)
            #endif

            let fileContents: String
            do {
                fileContents = try String(contentsOf: source.url)
            } catch {
                continue
            }

            var patterns: [NSRegularExpression] = []
            if let kind = source.kind, kind.starts(with: "sourcecode") {
                patterns.append(contentsOf: [
                    // note prioritized order: strip block comments before line comments
                    SourcePatterns.blockComments, SourcePatterns.lineComments,
                ])
            } else if source.kind == "text.xml" || source.kind == "text.html" ||
                source.url.pathExtension == "xml" || source.url.pathExtension == "html"
            {
                patterns.append(SourcePatterns.htmlComments)
            } else if source.kind == "text.plist.xml" || source.url.pathExtension == "plist",
                project.referencesPropertyListAsInfoPlist(named: source)
            {
                patterns.append(SourcePatterns.appFonts)
            }

            let strippedFileContents = fileContents
                .removingOccurrences(matchingExpressions: patterns)

            res.removeAll { resource -> Bool in
                for resourceName in resource.nameVariants {
                    let searchStrings: [String]
                    if let kind = source.kind, kind.starts(with: "sourcecode") {
                        // search for quoted strings in anything considered sourcecode;
                        // e.g. `UIImage(named: "Icon10")`
                        // however, consider the case:
                        //      `loadspr("res/monster.png")`
                        // here, the resource is actually "monster.png", but a build/copy phase
                        // has moved the resource to another destination; this means searching
                        //      `"monster.png"`
                        // won't work out as we want it to; instead, we can just try to match
                        // the end, which should work out no matter the destination, while
                        // still being decently specific; e.g.
                        //      `/monster.png"`
                        searchStrings = ["\"\(resourceName)\"", "/\(resourceName)\""]
                    } else if source.kind == "text.plist.xml" ||
                        source.url.pathExtension == "plist"
                    {
                        // search property-lists; typically only node contents
                        // e.g. "<key>Icon10</key>"
                        searchStrings = [">\(resourceName)<"]
                    } else {
                        // search any other text-based source; quoted strings and node content
                        // e.g. "<key>Icon10</key>"
                        //      "<key attr="Icon10">asdasd</key>"
                        searchStrings = ["\"\(resourceName)\"", ">\(resourceName)<"]
                    }
                    for searchString in searchStrings {
                        if strippedFileContents.contains(searchString) {
                            // resource seems to be used; remove and don't search further for this
                            return true
                        }
                    }
                }
                // resource seems to be unused; don't remove and keep searching for usages
                return false
            }
        }

        progress?(sources.count, sources.count, nil)

        if !res.isEmpty {
            return Diagnosis(
                conclusion: "unused resources",
                help: """
                These files might not be used; consider whether they should be removed.
                Note that this diagnosis is prone to false-positives as it can't realistically
                detect all usage patterns with certainty. Proceed with caution.
                """,
                cases: res.map { resource -> String in
                    // prefer name including extension, as this can help distinguish
                    // between asset catalog resources and plain resources not catalogued
                    resource.fileName ?? resource.name
                }
            )
        }
    case .emptyGroups:
        let groupPaths = emptyGroupPaths(in: project)
        if !groupPaths.isEmpty {
            return Diagnosis(
                conclusion: "empty groups",
                help: """
                These groups contain zero children and might be redundant;
                consider whether they should be removed.
                """,
                cases: groupPaths
            )
        }
    case .emptyTargets:
        let targetNames = emptyTargetNames(in: project)
        if !targetNames.isEmpty {
            return Diagnosis(
                conclusion: "empty targets",
                help: """
                These targets do not compile any sources and might be redundant;
                consider whether they should be removed.
                """,
                cases: targetNames
            )
        }
    }
    return nil
}
