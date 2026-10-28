#if canImport(JavaScriptCore)
import AppKit
import CodexBarCore

// Standalone menu-bar status items for user plugins (`manifest.topLevel`), available when Merge
// Icons is disabled. Every item needs the per-plugin "Show as separate menu bar icon" opt-in in
// Settings → Plugins, which defaults to OFF, so existing appended-card placement is unchanged until
// the user enables the item explicitly. Bundled plugin-based providers keep their regular provider
// item; the separate item only exists for dynamic user plugins (no first-party provider instance).

extension StatusItemController {
    /// Pure eligibility seam for tests: which plugins earn their own status item right now.
    nonisolated static func userPluginStatusItemPlugins(
        _ plugins: [UserProviderPlugin],
        isEnabled: (ProviderInstanceID) -> Bool,
        isStatusItemEnabled: (ProviderInstanceID) -> Bool,
        mergeIcons: Bool) -> [UserProviderPlugin]
    {
        guard !mergeIcons else { return [] }
        return plugins.filter { plugin in
            plugin.manifest.topLevel
                && plugin.manifest.id.firstPartyProvider == nil
                && isEnabled(plugin.manifest.id)
                && isStatusItemEnabled(plugin.manifest.id)
        }
    }

    /// Installed, enabled, top-level plugins whose separate status item is enabled and that do not
    /// collide with a built-in provider instance. Merge Icons ON always keeps appended cards.
    func userPluginStatusItemPlugins() -> [UserProviderPlugin] {
        Self.userPluginStatusItemPlugins(
            UserProviderPluginRegistry.all,
            isEnabled: self.settings.isPluginEnabled,
            isStatusItemEnabled: self.settings.isPluginTopLevelStatusItemEnabled,
            mergeIcons: self.shouldMergeIcons)
    }

    /// The quota window behind the plugin item's percent, from the plugin's "Menu bar metric"
    /// picker (stored as the per-plugin menu-bar layout override, like the switcher gauge).
    nonisolated static func userPluginMenuBarMetricPreference(
        layout: MenuBarLayout) -> MenuBarPercentWindowPreference
    {
        MenuBarPercentWindowPreference.current(in: layout) ?? .automatic
    }

    /// Retrieves or vends the plugin's status item with its stable autosave identity and card menu.
    func lazyPluginStatusItem(
        for plugin: UserProviderPlugin,
        onCreated: ((NSStatusItem) -> Void)? = nil)
        -> NSStatusItem
    {
        let instanceID = plugin.manifest.id
        if let existing = self.statusItems[instanceID] {
            return existing
        }
        let item = Self.makeStatusItem(
            create: self.statusBar.statusItem(withLength:),
            identity: .userPlugin(instanceID),
            defaults: self.settings.userDefaults,
            legacyDefaultItemIndex: nil,
            onCreated: { vended in
                // Register before invoking the caller/setup callbacks, mirroring lazyStatusItem:
                // button configuration and icon-observation can synchronously re-enter vending.
                self.statusItems[instanceID] = vended
            })
        // VoiceOver reads the plugin name instead of the generic CodexBar title.
        item.button?.setAccessibilityTitle(plugin.manifest.name)
        item.menu = self.pluginStatusItemMenu(for: plugin)
        onCreated?(item)
        return item
    }

    /// Creates the visible items for eligible plugins and removes any whose eligibility lapsed
    /// (toggle off, plugin disabled, removed, or Merge Icons re-enabled). Called from
    /// `updateVisibility`, so a settings toggle updates the menu bar immediately.
    func syncUserPluginStatusItems(expectedVisibleAutosaveNames: inout Set<String>) {
        let plugins = self.userPluginStatusItemPlugins()
        let visibleIDs = Set(plugins.map(\.manifest.id))
        for plugin in plugins {
            let item = self.lazyPluginStatusItem(for: plugin)
            self.setStatusItemVisiblePreservingPlacement(item, true)
            expectedVisibleAutosaveNames.insert(item.autosaveName)
        }
        let ownedItemIDs = Array(self.statusItems.keys)
            .filter { $0.firstPartyProvider == nil && !visibleIDs.contains($0) }
        for instanceID in ownedItemIDs {
            self.removeUserPluginStatusItem(for: instanceID)
        }
    }

    /// Removes a plugin status item together with its card menu and delegate. Delegates to the
    /// provider removal path so placement preservation and icon-signature cleanup behave identically.
    func removeUserPluginStatusItem(for instanceID: ProviderInstanceID) {
        self.removeProviderStatusItem(for: instanceID)
    }

    // MARK: Icon rendering

    /// Renders icon and percent for every vended plugin item. Mirrors the merged plugin-selection
    /// icon (brand icon + metric percent, or the two-lane meter), but only for items that already
    /// exist: item lifetime is owned by `updateVisibility`, so this pass never re-creates items and
    /// stays free of approval-store reads on the store-observation hot path.
    func applyUserPluginStatusItemIcons(phase: Double?) {
        let instanceIDs = self.statusItems.keys
            .filter { $0.firstPartyProvider == nil && UserProviderPluginRegistry.plugin(for: $0) != nil }
            .sorted { $0.rawValue < $1.rawValue }
        for instanceID in instanceIDs {
            guard let item = self.statusItems[instanceID],
                  let plugin = UserProviderPluginRegistry.plugin(for: instanceID)
            else { continue }
            self.applyPluginStatusItemIcon(plugin, to: item, phase: phase)
        }
    }

    private func applyPluginStatusItemIcon(_ plugin: UserProviderPlugin, to item: NSStatusItem, phase _: Double?) {
        guard let button = item.button else { return }
        let instanceID = plugin.manifest.id
        let signature = self.pluginStatusItemRenderSignature(plugin)
        guard self.lastAppliedProviderIconRenderSignatures[instanceID] != signature else { return }
        self.lastAppliedProviderIconRenderSignatures[instanceID] = signature
        let showUsed = self.settings.usageBarsShowUsed
        let showBrand = self.settings.menuBarShowsBrandIconWithPercent
        let snapshot = self.store.menuBarSnapshot(for: instanceID)
        let percent = Self.pluginSwitcherMetricPercent(
            snapshot: snapshot,
            showUsed: showUsed,
            preference: Self.userPluginMenuBarMetricPreference(
                layout: self.settings.menuBarLayout(forPlugin: instanceID)))
        let lanes = Self.pluginMeterPercents(snapshot: snapshot, showUsed: showUsed)
        let image = showBrand
            ? self.userPluginSwitcherIcon(for: plugin)
            : IconRenderer.makeIcon(
                primaryRemaining: lanes.primary,
                weeklyRemaining: lanes.secondary,
                creditsRemaining: nil,
                stale: self.store.errors[instanceID] != nil,
                style: .combined,
                hideCritters: true)
        item.length = NSStatusItem.variableLength
        self.setButtonContent(
            image: image,
            title: showBrand ? percent.map(UsageFormatter.percentString) ?? "—" : nil,
            tint: nil,
            for: button)
    }

    /// Color-mode/contrast changes bypass the data signature: drop plugin signatures so the next
    /// render pass repaints every plugin item with the current appearance.
    func refreshUserPluginStatusItemContentForColorMode() {
        for instanceID in self.statusItems.keys where instanceID.firstPartyProvider == nil {
            self.lastAppliedProviderIconRenderSignatures.removeValue(forKey: instanceID)
        }
        self.applyUserPluginStatusItemIcons(phase: nil)
    }

    private func pluginStatusItemRenderSignature(_ plugin: UserProviderPlugin) -> String {
        let instanceID = plugin.manifest.id
        let showUsed = self.settings.usageBarsShowUsed
        let snapshot = self.store.menuBarSnapshot(for: instanceID)
        let percent = Self.pluginSwitcherMetricPercent(
            snapshot: snapshot,
            showUsed: showUsed,
            preference: Self.userPluginMenuBarMetricPreference(
                layout: self.settings.menuBarLayout(forPlugin: instanceID)))
        let lanes = Self.pluginMeterPercents(snapshot: snapshot, showUsed: showUsed)
        return [
            plugin.sourceHash,
            "brand=\(self.settings.menuBarShowsBrandIconWithPercent ? "1" : "0")",
            "percent=\(Self.iconSignatureValue(percent))",
            "primary=\(Self.iconSignatureValue(lanes.primary))",
            "weekly=\(Self.iconSignatureValue(lanes.secondary))",
            "error=\(self.store.errors[instanceID] != nil ? "1" : "0")",
            "highContrast=\(self.shouldUseHighContrastStatusItemContent ? "1" : "0")",
        ].joined(separator: "|")
    }

    // MARK: Card menu

    /// The plugin item's menu: a single plugin card (usage, refresh, errors, last update). It is a
    /// standalone `NSMenu` with a dedicated delegate, deliberately outside the provider menu
    /// pipeline (`providerMenus`, open-menu tracking, closed-menu prewarm) so no provider rebuild
    /// can overwrite the card. `menuNeedsUpdate` repopulates on every open, so the card reflects
    /// the latest snapshot without in-open rebuild scheduling.
    func pluginStatusItemMenu(for plugin: UserProviderPlugin) -> NSMenu {
        let instanceID = plugin.manifest.id
        if let existing = self.pluginStatusItemMenus[instanceID] {
            return existing
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        StatusMenuAppearance.pin(menu)
        let delegate = UserPluginStatusItemMenuDelegate(controller: self, instanceID: instanceID)
        self.pluginStatusItemMenuDelegates[instanceID] = delegate
        menu.delegate = delegate
        self.pluginStatusItemMenus[instanceID] = menu
        return menu
    }

    func repopulateUserPluginStatusItemMenu(_ menu: NSMenu, instanceID: ProviderInstanceID) {
        guard !self.hasPreparedForAppShutdown,
              let plugin = UserProviderPluginRegistry.plugin(for: instanceID)
        else { return }
        menu.removeAllItems()
        menu.addItem(self.makeUserPluginMenuCardItem(plugin, width: Self.menuCardBaseWidth))
    }
}

/// Weak-controller delegate repopulating the plugin item's card menu before each open.
@MainActor
final class UserPluginStatusItemMenuDelegate: NSObject, NSMenuDelegate {
    private weak var controller: StatusItemController?
    private let instanceID: ProviderInstanceID

    init(controller: StatusItemController, instanceID: ProviderInstanceID) {
        self.controller = controller
        self.instanceID = instanceID
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let controller else { return }
        controller.repopulateUserPluginStatusItemMenu(menu, instanceID: self.instanceID)
    }
}
#endif
