import AppKit
import CursorGaugeCore
import Foundation

/// Menu-bar status item: summary polling, popover details, model-event cache.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, GaugePopoverDelegate {
    private static let summaryRefreshInterval: TimeInterval = 5 * 60
    private static let staleOnFocus: TimeInterval = 2 * 60
    private static let modelsCacheTTL: TimeInterval = 15 * 60

    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let popoverController = GaugePopoverController()

    private var refreshTimer: Timer?
    private var summaryTask: Task<Void, Never>?
    private var modelsTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?

    private var lastSummarySuccessAt: Date?
    private var lastUsage: PeriodUsage?
    private var lastSummaryError: String?
    private var modelAggregates: [ModelUsageAggregate]?
    private var lastModelsSuccessAt: Date?
    private var lastModelsError: String?
    private var displayMode: StatusDisplayMode

    override init() {
        displayMode = AppPreferences.displayMode()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        super.init()

        popoverController.delegate = self
        popoverController.hostingPopover = popover
        popover.contentViewController = popoverController
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if let button = statusItem.button {
            button.title = formatLoadingStatus().title
            button.toolTip = "CursorGauge"
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        popoverController.syncDisplayMode(displayMode)
        applyLoading()
    }

    func start() {
        schedulePolling()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSummaryIfStale()
            }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSummaryIfStale()
            }
        }
        Task { await refreshSummary() }
    }

    func stop() {
        closePopover()
        refreshTimer?.invalidate()
        refreshTimer = nil
        summaryTask?.cancel()
        summaryTask = nil
        modelsTask?.cancel()
        modelsTask = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
            self.activeObserver = nil
        }
    }

    // MARK: - Popover

    @objc private func statusItemClicked(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        renderPopoverContent()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Ensure models load when details UI opens (if cache stale).
        Task { await ensureModelsIfNeeded(force: false) }
    }

    private func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func renderPopoverContent() {
        popoverController.syncDisplayMode(displayMode)

        if let usage = lastUsage, let at = lastSummarySuccessAt {
            popoverController.showOverview(usage: usage, lastUpdated: at)
        } else if let error = lastSummaryError {
            popoverController.showOverviewError(error)
        } else if summaryTask != nil {
            popoverController.showOverviewLoading()
        } else {
            popoverController.showOverviewLoading()
        }

        if modelsTask != nil {
            popoverController.showModelsLoading()
        } else if let rows = modelAggregates {
            popoverController.showModels(rows)
        } else if let error = lastModelsError {
            popoverController.showModelsError(error)
        } else {
            popoverController.showModelsStaleHint()
        }
    }

    // MARK: - GaugePopoverDelegate

    func popoverDidRequestRefresh() {
        Task {
            await refreshSummary()
            await ensureModelsIfNeeded(force: true)
        }
    }

    func popoverDidRequestOpenDashboard() {
        NSWorkspace.shared.open(dashboardUsageURL)
    }

    func popoverDidRequestQuit() {
        closePopover()
        NSApp.terminate(nil)
    }

    func popoverDidChangeDisplayMode(_ mode: StatusDisplayMode) {
        displayMode = mode
        AppPreferences.setDisplayMode(mode)
        if let usage = lastUsage {
            setTitle(formatStatusText(usage, displayMode: displayMode))
        }
    }

    // MARK: - Refresh

    private func schedulePolling() {
        refreshTimer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.summaryRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshSummary()
            }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func refreshSummaryIfStale() {
        let stale =
            lastSummarySuccessAt.map { Date().timeIntervalSince($0) >= Self.staleOnFocus } ?? true
        guard stale else { return }
        Task { await refreshSummary() }
    }

    private func refreshSummary() async {
        if summaryTask != nil { return }

        let task = Task { @MainActor in
            if lastUsage == nil {
                applyLoading()
            }
            if popover.isShown {
                popoverController.showOverviewLoading()
            }

            let (token, discovery) = discoverAccessToken()
            guard let token else {
                let reason: String
                if case .failed(let r) = discovery {
                    reason = r
                } else {
                    reason = "Access token missing."
                }
                applySummaryError(reason)
                return
            }

            let result = await fetchPeriodUsage(token: token)
            switch result {
            case .ok(let usage):
                let now = Date()
                lastUsage = usage
                lastSummarySuccessAt = now
                lastSummaryError = nil
                setTitle(formatStatusText(usage, displayMode: displayMode))
                if popover.isShown {
                    popoverController.showOverview(usage: usage, lastUpdated: now)
                }
            case .failed(let error, _):
                applySummaryError(error)
            }
        }
        summaryTask = task
        await task.value
        summaryTask = nil
    }

    private func modelsCacheIsFresh() -> Bool {
        guard lastModelsSuccessAt != nil, modelAggregates != nil else { return false }
        guard let at = lastModelsSuccessAt else { return false }
        return Date().timeIntervalSince(at) < Self.modelsCacheTTL
    }

    private func ensureModelsIfNeeded(force: Bool) async {
        if !force && modelsCacheIsFresh() {
            if let rows = modelAggregates, popover.isShown {
                popoverController.showModels(rows)
            }
            return
        }
        if modelsTask != nil { return }

        let task = Task { @MainActor in
            if popover.isShown {
                popoverController.showModelsLoading()
            }

            let (token, discovery) = discoverAccessToken()
            guard let token else {
                let reason: String
                if case .failed(let r) = discovery {
                    reason = r
                } else {
                    reason = "Access token missing."
                }
                lastModelsError = reason
                if popover.isShown {
                    popoverController.showModelsError(reason)
                }
                return
            }

            // Prefer bounds from the latest summary; wait for / trigger summary first if missing.
            if lastUsage?.periodStart == nil && lastUsage?.periodEnd == nil {
                if let summaryTask {
                    await summaryTask.value
                } else {
                    await refreshSummary()
                }
            }
            guard let usage = lastUsage,
                  usage.periodStart != nil || usage.periodEnd != nil
            else {
                let message = lastSummaryError
                    ?? "Billing cycle bounds unavailable; cannot scope model events."
                lastModelsError = message
                if popover.isShown {
                    popoverController.showModelsError(message)
                }
                return
            }

            let result = await fetchModelUsageAggregates(
                token: token,
                periodStart: usage.periodStart,
                periodEnd: usage.periodEnd
            )
            switch result {
            case .ok(let rows):
                modelAggregates = rows
                lastModelsSuccessAt = Date()
                lastModelsError = nil
                if popover.isShown {
                    popoverController.showModels(rows)
                }
            case .failed(let error, _):
                lastModelsError = error
                if popover.isShown {
                    popoverController.showModelsError(error)
                }
            }
        }
        modelsTask = task
        await task.value
        modelsTask = nil
    }

    private func applyLoading() {
        let loading = formatLoadingStatus()
        setTitle(loading.title)
        lastSummaryError = nil
    }

    private func applySummaryError(_ message: String) {
        lastSummaryError = message
        // Keep last good title if we have one; otherwise show error title.
        if lastUsage == nil {
            setTitle(formatErrorStatus(message).title)
        }
        if popover.isShown {
            popoverController.showOverviewError(message)
        }
    }

    private func setTitle(_ title: String) {
        if let button = statusItem.button {
            button.title = title
            button.toolTip = title
        }
    }
}
