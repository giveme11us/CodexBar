#if canImport(JavaScriptCore)
import AppKit
import CodexBarCore
import Observation
import Testing
@testable import CodexBar

@Suite(.serialized)
struct UserPluginStatusItemTests {
    // MARK: Identity and pure seams

    @Test
    @MainActor
    func `status item identity returns stable plugin autosave names`() throws {
        let pluginID = try #require(ProviderInstanceID(rawValue: "hermes-vps"))
        let identity = StatusItemController.StatusItemIdentity.userPlugin(pluginID)
        #expect(identity.autosaveName == "codexbar-plugin-hermes-vps")
        #expect(
            StatusItemController.StatusItemIdentity.userPlugin(pluginID).accessibilityIdentifier
                == "CodexBar.StatusItem.plugin.hermes-vps")
        #expect(StatusItemController.StatusItemIdentity.provider(.codex).autosaveName == "codexbar-codex")
    }

    @Test
    func `menu bar metric preference resolves the plugin item quota window`() throws {
        let snapshot = Self.pooledSnapshot
        #expect(StatusItemController.userPluginMenuBarMetricPreference(
            layout: MenuBarLayout(lines: [[.percent(window: .automatic)]])) == .automatic)
        #expect(StatusItemController.userPluginMenuBarMetricPreference(
            layout: MenuBarLayout(lines: [[.percent(window: .session)]])) == .session)
        #expect(StatusItemController.userPluginMenuBarMetricPreference(layout: MenuBarLayout(lines: [[.balance]]))
            == .automatic)
        let sessionPercent = try #require(StatusItemController.pluginSwitcherMetricPercent(
            snapshot: snapshot,
            showUsed: true,
            preference: StatusItemController.userPluginMenuBarMetricPreference(
                layout: MenuBarLayout(lines: [[.percent(window: .session)]]))))
        #expect(sessionPercent == 10)
        let tertiaryPercent = try #require(StatusItemController.pluginSwitcherMetricPercent(
            snapshot: snapshot,
            showUsed: true,
            preference: .tertiary))
        #expect(UsageFormatter.percentString(tertiaryPercent) == "77%")
    }

    // MARK: Preference persistence

    @Test
    @MainActor
    func `plugin separate item preference defaults off and persists per plugin`() async throws {
        let defaults = InMemoryUserDefaults()
        let settings = testSettingsStore(suiteName: "plugin-status-item", userDefaults: defaults)
        let pluginID = try #require(ProviderInstanceID(rawValue: "hermes-vps"))
        let otherID = try #require(ProviderInstanceID(rawValue: "other-vps"))

        #expect(!settings.isPluginTopLevelStatusItemEnabled(pluginID))
        #expect(settings.pluginTopLevelStatusItemsRaw.isEmpty)

        settings.setPluginTopLevelStatusItemEnabled(pluginID, enabled: true)
        #expect(settings.isPluginTopLevelStatusItemEnabled(pluginID))
        #expect(!settings.isPluginTopLevelStatusItemEnabled(otherID))
        let stored = defaults.dictionary(forKey: "pluginTopLevelStatusItems") as? [String: Bool]
        #expect(stored?["hermes-vps"] == true)
        #expect(stored?.keys.count == 1)

        // OFF is the default, so disabling drops the entry instead of storing false.
        settings.setPluginTopLevelStatusItemEnabled(pluginID, enabled: false)
        #expect(!settings.isPluginTopLevelStatusItemEnabled(pluginID))
        #expect((defaults.dictionary(forKey: "pluginTopLevelStatusItems") as? [String: Bool])?.isEmpty == true)

        settings.setPluginTopLevelStatusItemEnabled(pluginID, enabled: true)
        await confirmation { changed in
            withObservationTracking {
                _ = settings.menuObservationToken
            } onChange: {
                changed()
            }
            // The menu observer reads the flag, so toggling it updates the status items immediately.
            settings.setPluginTopLevelStatusItemEnabled(pluginID, enabled: false)
        }
    }

    @Test
    @MainActor
    func `plugin separate item preference survives a settings reload`() throws {
        let defaults = InMemoryUserDefaults()
        let pluginID = try #require(ProviderInstanceID(rawValue: "hermes-vps"))
        let settings = testSettingsStore(suiteName: "plugin-status-item-reload", userDefaults: defaults)
        settings.setPluginTopLevelStatusItemEnabled(pluginID, enabled: true)

        let reloaded = testSettingsStore(suiteName: "plugin-status-item-reloaded", userDefaults: defaults)
        #expect(reloaded.isPluginTopLevelStatusItemEnabled(pluginID))
        #expect(!reloaded.isPluginTopLevelStatusItemEnabled(.codex))
    }

    @Test
    @MainActor
    func `portable preferences round trip keeps plugin separate item flags`() throws {
        let defaults = InMemoryUserDefaults()
        let pluginID = try #require(ProviderInstanceID(rawValue: "hermes-vps"))
        let settings = testSettingsStore(suiteName: "plugin-status-item-portable", userDefaults: defaults)
        settings.setPluginTopLevelStatusItemEnabled(pluginID, enabled: true)

        let document = try settings.exportPreferences()
        try document.validate()
        let data = try document.encoded()
        #expect(String(data: data, encoding: .utf8)?.contains(pluginID.rawValue) == true)

        let imported = try PreferencesDocument(data: data)
        let target = testSettingsStore(suiteName: "plugin-status-item-imported", userDefaults: InMemoryUserDefaults())
        try target.importPreferences(imported)
        #expect(target.isPluginTopLevelStatusItemEnabled(pluginID))

        var rejected = PreferencesDocument()
        try rejected.set("pluginTopLevelStatusItems", ["not an id!": true])
        #expect(throws: PreferencesDocument.Error.self) { try rejected.validate() }
    }

    // MARK: Settings pane eligibility

    @Test
    @MainActor
    func `pane toggle appears only for top level plugins`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write(name: "top.js", source: Self.pluginSource(id: "top-meter", name: "Top Meter"))
        _ = try fixture.write(
            name: "nested.js",
            source: Self.pluginSource(id: "nested-meter", name: "Nested Meter", topLevel: false))
        let plugins = UserProviderPluginRegistry.refresh(loader: fixture.loader()).compactMap(\.plugin)
        #expect(plugins.count == 2)
        let topLevel = try #require(plugins.first { $0.manifest.id.rawValue == "top-meter" })
        let nested = try #require(plugins.first { $0.manifest.id.rawValue == "nested-meter" })
        #expect(PluginsPane.supportsSeparateStatusItem(topLevel))
        #expect(!PluginsPane.supportsSeparateStatusItem(nested))
    }

    // MARK: Eligibility

    @Test
    @MainActor
    func `separate status item eligibility follows manifest enablement toggle and merge icons`() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write(name: "elig.js", source: Self.pluginSource(id: "elig-meter", name: "Elig Meter"))
        _ = try fixture.write(
            name: "flat.js",
            source: Self.pluginSource(id: "flat-meter", name: "Flat Meter", topLevel: false))
        let plugins = UserProviderPluginRegistry.refresh(loader: fixture.loader()).compactMap(\.plugin)
        let pluginID = try #require(plugins.first { $0.manifest.id.rawValue == "elig-meter" }?.manifest.id)

        func eligible(
            isEnabled: Bool,
            isStatusItemEnabled: Bool,
            mergeIcons: Bool) -> [ProviderInstanceID]
        {
            StatusItemController.userPluginStatusItemPlugins(
                plugins,
                isEnabled: { $0 == pluginID && isEnabled },
                isStatusItemEnabled: { _ in isStatusItemEnabled },
                mergeIcons: mergeIcons).map(\.manifest.id)
        }

        #expect(eligible(isEnabled: true, isStatusItemEnabled: true, mergeIcons: false) == [pluginID])
        #expect(eligible(isEnabled: true, isStatusItemEnabled: true, mergeIcons: true).isEmpty)
        #expect(eligible(isEnabled: true, isStatusItemEnabled: false, mergeIcons: false).isEmpty)
        #expect(eligible(isEnabled: false, isStatusItemEnabled: true, mergeIcons: false).isEmpty)
    }

    // MARK: Controller lifecycle

    @Test
    @MainActor
    func `enabled top level plugin with the opt in vends its own status item`() throws {
        let pluginID = try #require(ProviderInstanceID(rawValue: "item-meter"))
        let (_, controller, fixture) = try self.makePluginStatusItemController(
            suiteName: "plugin-status-item-vend",
            pluginID: pluginID,
            statusItemEnabled: true)
        defer {
            controller.releaseStatusItemsForTesting()
            fixture.remove()
        }

        let item = try #require(controller.statusItems[pluginID])
        #expect(item.autosaveName == "codexbar-plugin-item-meter")
        #expect(item.button?.accessibilityIdentifier() == "CodexBar.StatusItem.plugin.item-meter")
        #expect(item.button?.accessibilityTitle() == "Item Meter")
        #expect(item.isVisible)
        #expect(controller.expectedVisibleStatusItemAutosaveNames.contains("codexbar-plugin-item-meter"))
        #expect(controller.pluginStatusItemMenus[pluginID] != nil)
        #expect(controller.pluginStatusItemMenuDelegates[pluginID] != nil)

        // The item opens a menu holding exactly this plugin's card.
        let menu = try #require(controller.pluginStatusItemMenus[pluginID])
        controller.repopulateUserPluginStatusItemMenu(menu, instanceID: pluginID)
        #expect(menu.items.map { $0.representedObject as? String } == ["pluginCard:item-meter"])
    }

    @Test
    @MainActor
    func `toggling the opt in off removes the plugin status item`() throws {
        let pluginID = try #require(ProviderInstanceID(rawValue: "item-meter"))
        let (settings, controller, fixture) = try self.makePluginStatusItemController(
            suiteName: "plugin-status-item-toggle-off",
            pluginID: pluginID,
            statusItemEnabled: true)
        defer {
            controller.releaseStatusItemsForTesting()
            fixture.remove()
        }
        #expect(controller.statusItems[pluginID] != nil)

        settings.setPluginTopLevelStatusItemEnabled(pluginID, enabled: false)
        controller.handleProviderConfigChange(reason: "toggle off")

        #expect(controller.statusItems[pluginID] == nil)
        #expect(!controller.expectedVisibleStatusItemAutosaveNames.contains("codexbar-plugin-item-meter"))
        #expect(controller.pluginStatusItemMenus[pluginID] == nil)
        #expect(controller.pluginStatusItemMenuDelegates[pluginID] == nil)

        // Toggling back on vends the item again.
        settings.setPluginTopLevelStatusItemEnabled(pluginID, enabled: true)
        controller.handleProviderConfigChange(reason: "toggle on")
        #expect(controller.statusItems[pluginID]?.autosaveName == "codexbar-plugin-item-meter")
    }

    @Test
    @MainActor
    func `disabling the plugin removes its status item`() throws {
        let pluginID = try #require(ProviderInstanceID(rawValue: "item-meter"))
        let (settings, controller, fixture) = try self.makePluginStatusItemController(
            suiteName: "plugin-status-item-disable",
            pluginID: pluginID,
            statusItemEnabled: true)
        defer {
            controller.releaseStatusItemsForTesting()
            fixture.remove()
        }
        #expect(controller.statusItems[pluginID] != nil)

        settings.setPluginEnabled(pluginID, enabled: false)
        controller.handleProviderConfigChange(reason: "plugin disabled")

        #expect(controller.statusItems[pluginID] == nil)
        #expect(controller.pluginStatusItemMenus[pluginID] == nil)
    }

    @Test
    @MainActor
    func `plugins without top level never vend a separate item`() throws {
        let pluginID = try #require(ProviderInstanceID(rawValue: "item-meter"))
        let (settings, controller, fixture) = try self.makePluginStatusItemController(
            suiteName: "plugin-status-item-nested",
            pluginID: pluginID,
            statusItemEnabled: true,
            topLevel: false)
        defer {
            controller.releaseStatusItemsForTesting()
            fixture.remove()
        }

        // The preference alone never overrides the manifest.
        #expect(settings.isPluginTopLevelStatusItemEnabled(pluginID))
        #expect(controller.statusItems[pluginID] == nil)
        #expect(controller.pluginStatusItemMenus.isEmpty)
    }

    @Test
    @MainActor
    func `merge icons on keeps plugin items out of the menu bar`() throws {
        let pluginID = try #require(ProviderInstanceID(rawValue: "item-meter"))
        let (settings, controller, fixture) = try self.makePluginStatusItemController(
            suiteName: "plugin-status-item-merge-icons",
            pluginID: pluginID,
            statusItemEnabled: true)
        defer {
            controller.releaseStatusItemsForTesting()
            fixture.remove()
        }
        #expect(controller.statusItems[pluginID] != nil)

        settings.mergeIcons = true
        controller.handleProviderConfigChange(reason: "merge icons")

        #expect(controller.statusItems[pluginID] == nil)
        #expect(controller.pluginStatusItemMenus[pluginID] == nil)
        #expect(controller.statusItem.isVisible)

        settings.mergeIcons = false
        controller.handleProviderConfigChange(reason: "separate icons")
        #expect(controller.statusItems[pluginID] != nil)
    }

    @Test
    @MainActor
    func `removing the plugin removes its status item`() throws {
        let pluginID = try #require(ProviderInstanceID(rawValue: "item-meter"))
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write(name: "item.js", source: Self.pluginSource(id: "item-meter", name: "Item Meter"))
        let plugins = UserProviderPluginRegistry.refresh(loader: fixture.loader()).compactMap(\.plugin)
        #expect(plugins.count == 1)

        let (settings, controller, helperFixture) = try self.makePluginStatusItemController(
            suiteName: "plugin-status-item-removal",
            pluginID: pluginID,
            statusItemEnabled: true,
            pluginInstalled: false)
        #expect(controller.statusItems[pluginID] != nil)

        // Deleting the file and rediscovering retires the item, like Settings → Plugins → Delete.
        _ = try? FileManager.default.removeItem(at: fixture.providers.appendingPathComponent("item.js"))
        _ = UserProviderPluginRegistry.refresh(loader: fixture.loader(pluginsDirectory: fixture.empty))
        settings.updateProviderState(config: settings.configSnapshot)
        controller.handleProviderConfigChange(reason: "plugin removed")

        #expect(controller.statusItems[pluginID] == nil)
        #expect(controller.pluginStatusItemMenus[pluginID] == nil)
        controller.releaseStatusItemsForTesting()
        helperFixture.remove()
    }

    // MARK: Fixtures and helpers

    private static func pluginSource(id: String, name: String, topLevel: Bool? = nil) -> String {
        """
        defineProvider({
          id: "\(id)",
          name: "\(name)",
          \(topLevel.map { "topLevel: \($0)," } ?? "")
          endpoints: ["https://\(id).example"],
          settings: [],
          fetchUsage() { return { primary: { usedPercent: 12 } }; },
        });
        """
    }

    private static var pooledSnapshot: UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 10,
                windowMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 1_800_000_000),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 0,
                windowMinutes: 10080,
                resetsAt: Date(timeIntervalSince1970: 1_800_500_000),
                resetDescription: nil),
            tertiary: RateWindow(
                usedPercent: 76.9,
                windowMinutes: 43200,
                resetsAt: Date(timeIntervalSince1970: 1_802_500_000),
                resetDescription: nil,
                title: "Monthly"),
            updatedAt: .distantPast)
    }

    @MainActor
    private func makePluginStatusItemController(
        suiteName: String,
        pluginID: ProviderInstanceID,
        statusItemEnabled: Bool,
        topLevel: Bool = true,
        pluginInstalled: Bool = true) throws
        -> (SettingsStore, StatusItemController, Fixture)
    {
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let fixture = try Fixture()
        if pluginInstalled {
            _ = try fixture.write(
                name: "item.js",
                source: Self.pluginSource(id: pluginID.rawValue, name: "Item Meter", topLevel: topLevel))
            _ = UserProviderPluginRegistry.refresh(loader: fixture.loader())
        }

        let settings = testSettingsStore(suiteName: suiteName, userDefaults: InMemoryUserDefaults())
        settings.providerDetectionCompleted = true
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: false)
        }
        settings.setPluginEnabled(pluginID, enabled: true)
        if statusItemEnabled {
            settings.setPluginTopLevelStatusItemEnabled(pluginID, enabled: true)
        }

        let store = UsageStore(
            fetcher: UsageFetcher(),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            pluginApprovalStore: ProviderPluginApprovalStore(fileURL: URL(fileURLWithPath: "/dev/null")))
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        return (settings, controller, fixture)
    }
}

private struct Fixture {
    let root: URL
    let providers: URL
    let empty: URL
    let cache: URL

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UserPluginStatusItemTests-\(UUID().uuidString)", isDirectory: true)
        self.providers = self.root.appendingPathComponent("providers", isDirectory: true)
        self.empty = self.root.appendingPathComponent("empty", isDirectory: true)
        self.cache = self.root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: self.providers, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: self.empty, withIntermediateDirectories: true)
    }

    func write(name: String, source: String) throws -> URL {
        let url = self.providers.appendingPathComponent(name)
        try Data(source.utf8).write(to: url, options: .atomic)
        return url
    }

    func loader(pluginsDirectory: URL? = nil) -> UserProviderPluginLoader {
        UserProviderPluginLoader(
            providersDirectory: pluginsDirectory ?? self.providers,
            cacheDirectory: self.cache,
            transport: NoopTransport())
    }

    func remove() {
        UserProviderPluginRegistry.refresh(loader: self.loader(pluginsDirectory: self.empty))
        try? FileManager.default.removeItem(at: self.root)
    }
}

private final class NoopTransport: ProviderHTTPTransport, @unchecked Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: 500,
            httpVersion: nil,
            headerFields: nil) ?? URLResponse()
        return (Data("{}".utf8), response)
    }
}
#endif
