// swift-tools-version: 6.2

import Darwin
import Foundation
import PackageDescription

let fileManager = FileManager.default
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let muPDFBuildRoot = packageRoot.appendingPathComponent("Vendor/mupdf/build/macos-arm64")
let muPDFLibraryDirectory = muPDFBuildRoot.appendingPathComponent("lib")
let muPDFIncludeDirectory = muPDFBuildRoot.appendingPathComponent("include")
let muPDFGeneratedDirectory = muPDFBuildRoot.appendingPathComponent("generated")

let hasMuPDFArtifacts = fileManager.fileExists(
    atPath: muPDFLibraryDirectory.appendingPathComponent("libmupdf.a").path
)

if !hasMuPDFArtifacts {
    fputs(
        "warning: MuPDF artifacts are missing. Run ./Scripts/fetch-mupdf-build.sh to install the pinned bridge artifacts.\n",
        stderr
    )
}

var bridgeCSettings: [CSetting] = []
var bridgeLinkerSettings: [LinkerSetting] = []

if hasMuPDFArtifacts {
    bridgeCSettings = [
        .define("PDF_EDITOR_BRIDGE_WITH_MUPDF", to: "1"),
        .unsafeFlags([
            "-I", muPDFIncludeDirectory.path,
            "-I", muPDFGeneratedDirectory.path,
        ]),
    ]

    bridgeLinkerSettings = [
        .unsafeFlags(["-L", muPDFLibraryDirectory.path]),
        .linkedLibrary("mupdf"),
    ]

    if fileManager.fileExists(atPath: muPDFLibraryDirectory.appendingPathComponent("libmupdf-third.a").path) {
        bridgeLinkerSettings.append(.linkedLibrary("mupdf-third"))
    }

    if fileManager.fileExists(atPath: muPDFLibraryDirectory.appendingPathComponent("libmupdf-threads.a").path) {
        bridgeLinkerSettings.append(.linkedLibrary("mupdf-threads"))
    }

    if fileManager.fileExists(atPath: muPDFLibraryDirectory.appendingPathComponent("libmupdf-pkcs7.a").path) {
        bridgeLinkerSettings.append(.linkedLibrary("mupdf-pkcs7"))
    }
}

let package = Package(
    name: "PdfEditor",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "PdfEditorCore",
            targets: ["PdfEditorCore"]
        ),
        .executable(
            name: "PdfEditorApp",
            targets: ["PdfEditorApp"]
        ),
    ],
    targets: [
        .target(
            name: "CPdfEngineBridge",
            publicHeadersPath: "include",
            cSettings: bridgeCSettings,
            linkerSettings: bridgeLinkerSettings
        ),
        .target(
            name: "PdfEditorCore",
            dependencies: ["CPdfEngineBridge"]
        ),
        .executableTarget(
            name: "PdfEditorApp",
            dependencies: ["PdfEditorCore"]
        ),
        .testTarget(
            name: "PdfEditorCoreTests",
            dependencies: ["PdfEditorCore"]
        ),
    ]
)
