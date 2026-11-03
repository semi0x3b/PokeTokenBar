import AppKit
import SwiftUI
import Vision
import XCTest
@testable import PokeTokenBar

/// "Before" renders of main's original UI for the sulk/back-view PR. Test-only, **skipped unless
/// `PTB_SULK_RENDER_DIR` names a directory**. Sizes and styles mirror the "after" renders in
/// `SulkRenderTests` on the feature branch, so the pairs compare one to one.
@MainActor
final class SulkBeforeRenderTests: XCTestCase {
    private var windows: [NSWindow] = []

    override func tearDown() async throws {
        windows.forEach { $0.close() }
        windows = []
    }

    private func outputDirectory() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["PTB_SULK_RENDER_DIR"], !path.isEmpty else {
            throw XCTSkip("PTB_SULK_RENDER_DIR not set — render only when asked")
        }
        return URL(fileURLWithPath: path)
    }

    private func mount<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSHostingView<AnyView> {
        let host = NSHostingView(rootView: AnyView(
            view.frame(width: width, height: height).background(Color.white).environment(\.colorScheme, .light)))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: width, height: height),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFront(nil)
        windows.append(window)
        return host
    }

    private func snapshot(_ host: NSView) async throws -> Data {
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let bounds = host.bounds
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
        host.cacheDisplay(in: bounds, to: rep)
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }

    // MARK: Menu illustrations (same drawing as the "after" illustrations)

    private struct MenuRow: Identifiable {
        let id = UUID()
        let title: String
        var checked = false
        var shortcut = ""
        var enabled = true
        var isSeparator = false
    }

    private func menuIllustration(_ rows: [MenuRow], width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                if row.isSeparator {
                    Divider().padding(.vertical, 4)
                } else {
                    HStack(spacing: 0) {
                        Text(row.checked ? "✓" : "").frame(width: 20)
                        Text(row.title)
                        Spacer(minLength: 16)
                        Text(row.shortcut).foregroundColor(.secondary)
                    }
                    .font(.system(size: 13))
                    .foregroundColor(row.enabled ? .primary : .secondary)
                    .frame(height: 22)
                    .padding(.horizontal, 6)
                }
            }
        }
        .padding(6)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
        .padding(12)
    }

    private func writeIllustration<V: View>(_ view: V, name: String, size: CGSize, to directory: URL) async throws {
        let png = try await snapshot(mount(view, width: size.width, height: size.height))
        try png.write(to: directory.appendingPathComponent(name))
        print("wrote \(name) (\(png.count) bytes)")
    }

    func testRenderMenuIllustrationsBefore() async throws {
        let directory = try outputDirectory()
        let l = L(.en)
        let petRows = [MenuRow(title: l.floatingPetMenuOpen), MenuRow(title: l.floatingPetMenuHide)]
        try await writeIllustration(menuIllustration(petRows, width: 220),
                                    name: "illustration-pet-menu-before-en.png",
                                    size: CGSize(width: 244, height: 120), to: directory)
        let entries = StatusItemMenu.entries(l: l, todayTokens: 19_400_000, todayCost: nil, floatingPetEnabled: false)
        let rows = entries.map { entry -> MenuRow in
            guard let entry else { return MenuRow(title: "", isSeparator: true) }
            return MenuRow(title: entry.title,
                           shortcut: entry.keyEquivalent.isEmpty ? "" : "⌘" + entry.keyEquivalent.uppercased(),
                           enabled: entry.action != nil)
        }
        try await writeIllustration(menuIllustration(rows, width: 280),
                                    name: "illustration-status-menu-before-en.png",
                                    size: CGSize(width: 304, height: 240), to: directory)
    }

    // MARK: Settings section

    private func crop(_ png: Data, from startTitle: String, to endTitle: String) throws -> Data {
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        let cgImage = try XCTUnwrap(rep.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: cgImage).perform([request])
        func topY(of title: String) -> CGFloat? {
            // Rows below a title may repeat its words ("Show floating pet"), so take the topmost match.
            let rows = (request.results ?? [])
                .filter { $0.topCandidates(1).first?.string.lowercased().contains(title.lowercased()) == true }
                .map { (1 - $0.boundingBox.maxY) * CGFloat(cgImage.height) }
            return rows.min()
        }
        guard let top = topY(of: startTitle), let bottom = topY(of: endTitle), bottom > top else {
            print("sulk-render crop: titles not found, writing the full page")
            return png
        }
        let margin: CGFloat = 16
        let rect = CGRect(x: 0, y: max(0, top - margin), width: CGFloat(cgImage.width), height: bottom - top)
        let cropped = try XCTUnwrap(cgImage.cropping(to: rect))
        return try XCTUnwrap(NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:]))
    }

    func testRenderSettingsFloatingPetSectionBefore() async throws {
        let directory = try outputDirectory()
        let suite = "SulkBeforeSettings-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(suite).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let usage = UsageStore(providers: [], autoRefresh: false, defaults: defaults)
        usage.floatingPetEnabled = true
        let companion = CompanionStore(fileURL: file, defaults: defaults)
        companion.setLanguage(.en)
        let view = SettingsView(onClose: {}, onChooseRepresentative: {})
            .environment(usage).environment(companion).environment(UpdateChecker())
        let page = try await snapshot(mount(view, width: PopoverMetrics.width, height: 2600))
        let l = L(.en)
        let section = try crop(page, from: l.floatingPetSectionTitle, to: l.notificationsSection)
        try section.write(to: directory.appendingPathComponent("settings-floating-pet-before-en.png"))
        print("wrote settings-floating-pet-before-en.png (\(section.count) bytes)")
    }
}
