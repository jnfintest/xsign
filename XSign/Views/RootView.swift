import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $model.selectedTab) {
                ReposView().tag(AppTab.repos).toolbar(.hidden, for: .tabBar)
                AppsView().tag(AppTab.apps).toolbar(.hidden, for: .tabBar)
                HomeView().tag(AppTab.home).toolbar(.hidden, for: .tabBar)
                LibraryView().tag(AppTab.library).toolbar(.hidden, for: .tabBar)
                SettingsView().tag(AppTab.settings).toolbar(.hidden, for: .tabBar)
            }
            FloatingTabBar(selection: $model.selectedTab, badges: [.home: model.pendingUpdates.count])
        }
        .ignoresSafeArea(.keyboard)
    }
}

/// Capsule tab bar floating above the content.
struct FloatingTabBar: View {
    @Binding var selection: AppTab
    var badges: [AppTab: Int] = [:]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                Button {
                    if selection != tab { Haptics.tap() }
                    selection = tab
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 19, weight: .semibold))
                            .overlay(alignment: .topTrailing) {
                                if let count = badges[tab], count > 0 {
                                    Text("\(count)")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .frame(minWidth: 17, minHeight: 17)
                                        .background(Theme.accent, in: Capsule())
                                        .offset(x: 12, y: -8)
                                }
                            }
                        Text(tab.title).font(.caption2.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundStyle(selection == tab ? Theme.accent : Color.primary)
                    .background(selection == tab ? Color.primary.opacity(0.08) : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
            }
        }
        .padding(5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(Theme.stroke))
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .padding(.horizontal, 14)
        .padding(.bottom, 2)
    }
}
