import AppKit
import SwiftUI

@main
@MainActor
enum PulseBarMain {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--check-runtime") {
            // dyld loads linked frameworks before reaching this entry point.
            print("PulseBar runtime dependencies loaded.")
            return
        }
        if let index = arguments.firstIndex(of: "--render-panel"), arguments.indices.contains(index + 1) {
            renderPanel(to: arguments[index + 1], demo: arguments.contains("--demo"), expand: arguments.contains("--expand"))
            return
        }
        stopTunnelOnSIGTERM()
        PulseBarApp.main()
    }

    /// `kill <pid>` skips applicationWillTerminate; route SIGTERM through a normal quit so the SSH tunnel child stops too.
    private static var sigtermSource: DispatchSourceSignal?
    private static func stopTunnelOnSIGTERM() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { NSApplication.shared.terminate(nil) }
        source.resume()
        sigtermSource = source
    }

    /// Fetches sparkDash once (or uses demo data) and writes the panel as a PNG, for screenshots and checks.
    private static func renderPanel(to path: String, demo: Bool, expand: Bool) {
        _ = NSApplication.shared
        let model = FleetViewModel(demo: demo)
        let deadline = Date().addingTimeInterval(15)
        while model.lastUpdate == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        }
        let view = FleetPanelView(model: model, initiallyExpanded: expand ? model.snapshot.sparks.first?.id : nil, scrolls: false)
            .fixedSize(horizontal: false, vertical: true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(width: 400, height: nil)
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            print("render failed")
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print(model.reachable ? "rendered \(model.snapshot.sparks.count) hosts: \(model.menuBarTitle)" : "unreachable: \(model.errorText)")
        model.quit(stopApp: false)
    }
}
