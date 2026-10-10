import SwiftUI

@main
struct ScrollCueApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var scripts = ScriptStore()
    @StateObject private var stats = StatsStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(scripts)
                .environmentObject(stats)
                .preferredColorScheme(.dark)
                .tint(settings.settings.highlightColor.color)
        }
    }
}

/// Launch arguments used by the CI simulator smoke test.
enum LaunchArgs {
    static let args = ProcessInfo.processInfo.arguments
    static var openDemo: Bool { args.contains("-demoPrompter") }
    static var autoplay: Bool { args.contains("-demoAutoplay") }
    static var tab: Int { args.contains("-tabSettings") ? 1 : (args.contains("-tabStats") ? 2 : 0) }
}

struct RootView: View {
    @EnvironmentObject var stats: StatsStore
    @State private var tab = LaunchArgs.tab

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("Scripts", systemImage: "text.alignleft") }
                .tag(0)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                .tag(1)
            StatsView()
                .tabItem { Label("Stats", systemImage: "chart.bar") }
                .tag(2)
        }
        .overlay(alignment: .top) {
            if let m = stats.milestone {
                MilestoneBanner(words: m) { stats.milestone = nil }
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.spring, value: stats.milestone)
    }
}

struct MilestoneBanner: View {
    let words: Int
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("🎉")
            Text("\(words.formatted()) words spoken with ScrollCue!")
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .onTapGesture(perform: dismiss)
        .task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            dismiss()
        }
    }
}
