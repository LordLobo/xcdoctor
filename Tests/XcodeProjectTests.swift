//
//  XcodeProjectTests.swift
//  xcdoctor
//
//  Created by Jacob Hauberg Hansen on 26/06/2020.
//

@testable import XCDoctor

import Foundation
import XCTest

// note that paths in these tests assumes `$ swift test` from the root of the project;
// it does _not_ work when run from Xcode; some might still pass, but most will fail
class XcodeProjectTests: XCTestCase {
    func projectUrl(for defect: Defect) -> URL {
        URL(fileURLWithPath: "Tests/Subjects/")
            .appendingPathComponent(
                "\(defect)/xcdoctor.xcodeproj"
            )
    }

    func testProjectNotFoundInNonExistentPath() {
        let result = XcodeProject.open(from: URL(fileURLWithPath: "~/Some/Project.xcodeproj"))
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(
                error as! XcodeProjectError,
                XcodeProjectError.notFound(amongFilesInDirectory: false)
            )
        }
    }

    func testProjectNotFoundInNonExistentDirectory() {
        let result = XcodeProject.open(from: URL(fileURLWithPath: "~/Some/Place/"))
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(
                error as! XcodeProjectError,
                XcodeProjectError.notFound(amongFilesInDirectory: true)
            )
        }
    }

    func testProjectNotFoundInDirectory() {
        // assumes this directory is kept rid of .xcodeprojs
        let result = XcodeProject.open(from: URL(fileURLWithPath: "Tests/Subjects/"))
        XCTAssertThrowsError(try result.get()) { error in
            XCTAssertEqual(
                error as! XcodeProjectError,
                XcodeProjectError.notFound(amongFilesInDirectory: true)
            )
        }
    }

    func testProjectFound() {
        let result = XcodeProject.open(from: projectUrl(for: .nonExistentFiles))
        XCTAssertNoThrow(try result.get())
    }

    func testFileReferenceResolution() {
        let result = XcodeProject.open(from: projectUrl(for: .nonExistentFiles))
        guard let project = try? result.get() else {
            XCTFail(); return
        }
        XCTAssert(project.files.count == 1)
        // TODO: assert path is as expected
    }

    func testMissingFile() {
        let result = XcodeProject.open(from: projectUrl(for: .nonExistentFiles))
        guard let project = try? result.get() else {
            XCTFail(); return
        }
        let diagnosis = examine(project: project, for: .nonExistentFiles)
        XCTAssertNotNil(diagnosis)
        XCTAssertNotNil(diagnosis!.cases)
        XCTAssert(diagnosis!.cases!.count == 1)
    }

    func testCorruptPlist() {
        let result = XcodeProject.open(from: projectUrl(for: .corruptPropertyLists))
        guard let project = try? result.get() else {
            XCTFail(); return
        }
        let diagnosis = examine(project: project, for: .corruptPropertyLists)
        XCTAssertNotNil(diagnosis)
        XCTAssertNotNil(diagnosis!.cases)
        XCTAssert(diagnosis!.cases!.count == 1)
    }

    func testDanglingFile() {
        let result = XcodeProject.open(from: projectUrl(for: .danglingFiles))
        guard let project = try? result.get() else {
            XCTFail(); return
        }
        let diagnosis = examine(project: project, for: .danglingFiles)
        XCTAssertNotNil(diagnosis)
        XCTAssertNotNil(diagnosis!.cases)
        XCTAssert(diagnosis!.cases!.count == 1)
    }
}
