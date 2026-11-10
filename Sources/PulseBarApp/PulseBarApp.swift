import AppKit
import PulseBarUI
import SwiftUI

@MainActor
struct PulseBarApp: App {
    @StateObject private var fleet = FleetViewModel(demo: CommandLine.arguments.contains("--demo"))

    var body: some Scene {
        MenuBarExtra {
            FleetPanelView(model: fleet)
        } label: {
            FleetStatusItemLabel(model: fleet)
        }
        .menuBarExtraStyle(.window)
        .commands {
            FleetCommands(model: fleet)
        }
    }
}

@MainActor
private struct FleetStatusItemLabel: View {
    @ObservedObject var model: FleetViewModel

    var body: some View {
        if let image = renderedImage {
            Image(nsImage: image).accessibilityLabel(model.menuBarTitle)
        } else {
            Text(model.menuBarTitle).monospacedDigit()
        }
    }

    private var renderedImage: NSImage? {
        let renderer = ImageRenderer(
            content: HStack(spacing: 4) {
                Image(systemName: model.alerting ? "bolt.trianglebadge.exclamationmark.fill" : "bolt.fill")
                Text(model.menuBarTitle.replacingOccurrences(of: "⚡ ", with: ""))
            }
            .font(.system(size: NSFont.menuBarFont(ofSize: 0).pointSize))
            .monospacedDigit()
            .foregroundStyle(.black)
            .fixedSize()
        )
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = true
        return image
    }
}

@MainActor
struct FleetCommands: Commands {
    let model: FleetViewModel

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") { SparkleController.shared.checkForUpdates() }
                .disabled(!SparkleController.shared.canCheckForUpdates)
        }
        CommandGroup(replacing: .appTermination) {
            Button("Quit") { model.quit() }.keyboardShortcut("q", modifiers: .command)
        }
    }
}

@MainActor
struct PulseBarCommands: Commands {
    let viewModel: MetricsViewModel

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button {
                PulseBarNavigation.openPreferences(viewModel: viewModel)
            } label: {
                Label("Preferences…", systemImage: "gearshape")
            }
            .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                SparkleController.shared.checkForUpdates()
            }
            .disabled(!SparkleController.shared.canCheckForUpdates)
        }

        CommandGroup(replacing: .appTermination) {
            Button {
                viewModel.quit()
            } label: {
                Label("Quit", systemImage: "power")
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
