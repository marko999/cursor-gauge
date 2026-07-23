import AppKit
import CursorGaugeCore
import Foundation

@MainActor
protocol GaugePopoverDelegate: AnyObject {
    func popoverDidRequestRefresh()
    func popoverDidRequestOpenDashboard()
    func popoverDidRequestQuit()
    func popoverDidChangeDisplayMode(_ mode: StatusDisplayMode)
}

/// Native menu-bar popover: vibrancy material, compact sections, Models + Settings.
@MainActor
final class GaugePopoverController: NSViewController {
    weak var delegate: GaugePopoverDelegate?
    /// Set by `StatusItemController` so content-size updates stay on public AppKit APIs.
    weak var hostingPopover: NSPopover?

    private static let popoverWidth: CGFloat = 430
    private static let maxContentHeight: CGFloat = 560
    private static let minContentHeight: CGFloat = 320

    private let effectView = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()

    // Header
    private let titleLabel = NSTextField(labelWithString: "CursorGauge")
    private let remainingLabel = NSTextField(labelWithString: "—")
    private let updatedLabel = NSTextField(labelWithString: "")
    private let statusMessageLabel = NSTextField(wrappingLabelWithString: "")

    // Included
    private let includedUsedLabel = NSTextField(labelWithString: "")
    private let includedLimitLabel = NSTextField(labelWithString: "")
    private let includedRemainingLabel = NSTextField(labelWithString: "")
    private let includedProgress = NSProgressIndicator()

    // On-demand
    private let onDemandSection = NSStackView()
    private let onDemandUsedLabel = NSTextField(labelWithString: "")
    private let onDemandLimitLabel = NSTextField(labelWithString: "")
    private let onDemandRemainingLabel = NSTextField(labelWithString: "")
    private let onDemandProgress = NSProgressIndicator()

    // Stats rows
    private let autoRow = MetricRowView(title: "Auto")
    private let apiRow = MetricRowView(title: "API")
    private let totalRow = MetricRowView(title: "Plan used")
    private let resetRow = MetricRowView(title: "Resets")

    // Models
    private let modelsDisclosure = NSButton(checkboxWithTitle: "Models", target: nil, action: nil)
    private let modelsSummaryLabel = NSTextField(labelWithString: "")
    private let modelsDisclaimer = NSTextField(wrappingLabelWithString: "")
    private let modelsContainer = NSStackView()
    private let modelsListStack = NSStackView()
    private let modelsStatusLabel = NSTextField(wrappingLabelWithString: "")
    private var modelsExpanded = false

    // Settings
    private let settingsDisclosure = NSButton(checkboxWithTitle: "Settings", target: nil, action: nil)
    private let settingsContainer = NSStackView()
    private var displayModeButtons: [NSButton] = []
    private let launchAtLoginCheckbox = NSButton(
        checkboxWithTitle: "Launch at Login",
        target: nil,
        action: nil
    )
    private let launchStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let launchHintLabel = NSTextField(wrappingLabelWithString: "")
    private var settingsExpanded = false

    private var displayMode: StatusDisplayMode = .dollarsRemaining
    private var lastUsage: PeriodUsage?
    private var lastUpdated: Date?

    override func loadView() {
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        view = effectView

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 0
        contentStack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentStack

        effectView.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: effectView.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            contentStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])

        buildContent()
        preferredContentSize = NSSize(width: Self.popoverWidth, height: Self.minContentHeight)
        showOverviewLoading()
        syncLaunchAtLoginUI()
    }

    // MARK: - Public API (StatusItemController)

    func showOverviewLoading() {
        statusMessageLabel.isHidden = false
        statusMessageLabel.stringValue = "Refreshing Cursor plan usage…"
        remainingLabel.stringValue = "…"
        updatedLabel.stringValue = ""
        setMetricSectionsVisible(false)
        relayout()
    }

    func showOverviewError(_ message: String) {
        statusMessageLabel.isHidden = false
        statusMessageLabel.stringValue = [
            "Unable to load plan usage.",
            message,
            "Sign in to Cursor on this Mac if needed, then Refresh.",
        ].joined(separator: "\n")
        remainingLabel.stringValue = "?"
        updatedLabel.stringValue = ""
        setMetricSectionsVisible(false)
        relayout()
    }

    func showOverview(usage: PeriodUsage, lastUpdated: Date) {
        lastUsage = usage
        self.lastUpdated = lastUpdated
        statusMessageLabel.isHidden = true
        statusMessageLabel.stringValue = ""

        remainingLabel.stringValue = formatStatusText(usage, displayMode: displayMode)
        updatedLabel.stringValue = formatUpdatedLabel(lastUpdated)

        includedUsedLabel.stringValue = "Used  \(formatUsageAmount(usage.used, kind: usage.kind))"
        includedLimitLabel.stringValue = "Limit  \(formatUsageAmount(usage.limit, kind: usage.kind))"
        includedRemainingLabel.stringValue =
            "Remaining  \(formatUsageAmount(usage.remaining, kind: usage.kind))"
        configureProgress(includedProgress, used: usage.used, limit: usage.limit, label: "Included usage")

        let hasOnDemand =
            usage.onDemandLimit != nil || usage.onDemandUsed != nil || usage.onDemandRemaining != nil
        onDemandSection.isHidden = !hasOnDemand
        if hasOnDemand {
            let used = usage.onDemandUsed ?? 0
            onDemandUsedLabel.stringValue = "Used  \(formatUsageAmount(used, kind: usage.kind))"
            onDemandLimitLabel.stringValue =
                "Limit  \(usage.onDemandLimit.map { formatUsageAmount($0, kind: usage.kind) } ?? "—")"
            onDemandRemainingLabel.stringValue =
                "Remaining  \(usage.onDemandRemaining.map { formatUsageAmount($0, kind: usage.kind) } ?? "—")"
            if let limit = usage.onDemandLimit, limit > 0 {
                onDemandProgress.isHidden = false
                configureProgress(onDemandProgress, used: used, limit: limit, label: "On-demand usage")
            } else {
                onDemandProgress.isHidden = true
            }
        }

        autoRow.setValue(usage.autoPercentUsed.map { String(format: "%.1f%%", $0) } ?? "—")
        apiRow.setValue(usage.apiPercentUsed.map { String(format: "%.1f%%", $0) } ?? "—")
        totalRow.setValue(formatPlanUsedPercent(used: usage.used, limit: usage.limit))
        if let end = usage.periodEnd {
            resetRow.setValue(end.formatted(date: .abbreviated, time: .shortened))
        } else {
            resetRow.setValue("—")
        }

        setMetricSectionsVisible(true)
        relayout()
    }

    func showModelsLoading() {
        modelsStatusLabel.isHidden = false
        modelsStatusLabel.stringValue = "Loading model breakdown…"
        modelsListStack.isHidden = true
        modelsSummaryLabel.stringValue = ""
        modelsDisclaimer.isHidden = true
        relayout()
    }

    func showModelsError(_ message: String) {
        modelsStatusLabel.isHidden = false
        modelsStatusLabel.stringValue = [
            "Unable to load model attribution.",
            message,
        ].joined(separator: "\n")
        modelsListStack.isHidden = true
        modelsSummaryLabel.stringValue = ""
        modelsDisclaimer.isHidden = false
        modelsDisclaimer.stringValue =
            "Dashboard event attribution · not an invoice"
        relayout()
    }

    func showModels(_ rows: [ModelUsageAggregate]) {
        modelsStatusLabel.isHidden = true
        modelsStatusLabel.stringValue = ""
        modelsDisclaimer.isHidden = false
        modelsDisclaimer.stringValue =
            "Dashboard event attribution · not an invoice"
        if rows.isEmpty {
            modelsSummaryLabel.stringValue = "No events this billing cycle"
            modelsListStack.isHidden = true
            clearArranged(modelsListStack)
        } else {
            modelsSummaryLabel.stringValue = "\(rows.count) model\(rows.count == 1 ? "" : "s")"
            rebuildModelRows(rows)
            modelsListStack.isHidden = !modelsExpanded
        }
        relayout()
    }

    func showModelsStaleHint() {
        if modelsStatusLabel.stringValue.isEmpty && modelsListStack.arrangedSubviews.isEmpty {
            modelsStatusLabel.isHidden = false
            modelsStatusLabel.stringValue = "Expand Models or press Refresh to load attribution."
            modelsDisclaimer.isHidden = false
            modelsDisclaimer.stringValue =
                "Dashboard event attribution · not an invoice"
        }
        relayout()
    }

    func syncDisplayMode(_ mode: StatusDisplayMode) {
        displayMode = mode
        for button in displayModeButtons {
            button.state = button.tag == modeTag(mode) ? .on : .off
        }
        if let usage = lastUsage, let at = lastUpdated {
            remainingLabel.stringValue = formatStatusText(usage, displayMode: mode)
            updatedLabel.stringValue = formatUpdatedLabel(at)
        }
    }

    // MARK: - Build

    private func buildContent() {
        contentStack.addArrangedSubview(makeHeader())
        contentStack.addArrangedSubview(makeSeparator())
        contentStack.addArrangedSubview(makeIncludedSection())
        contentStack.addArrangedSubview(spacer(8))
        contentStack.addArrangedSubview(onDemandSection)
        configureOnDemandSection()
        contentStack.addArrangedSubview(makeSeparator())
        contentStack.addArrangedSubview(makeStatsSection())
        contentStack.addArrangedSubview(makeSeparator())
        contentStack.addArrangedSubview(makeModelsSection())
        contentStack.addArrangedSubview(makeSeparator())
        contentStack.addArrangedSubview(makeSettingsSection())
        contentStack.addArrangedSubview(makeSeparator())
        contentStack.addArrangedSubview(makeActionRow(
            title: "Refresh",
            symbol: "arrow.clockwise",
            accessibility: "Refresh usage data",
            action: #selector(refreshClicked)
        ))
        contentStack.addArrangedSubview(makeActionRow(
            title: "Open Cursor Usage Dashboard",
            symbol: "safari",
            accessibility: "Open Cursor Usage Dashboard in browser",
            action: #selector(dashboardClicked)
        ))
        contentStack.addArrangedSubview(makeActionRow(
            title: "Quit CursorGauge",
            symbol: "power",
            accessibility: "Quit CursorGauge",
            action: #selector(quitClicked)
        ))
        contentStack.addArrangedSubview(spacer(6))

        let footer = NSTextField(labelWithString: "Menu-bar only · local Cursor session")
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .tertiaryLabelColor
        footer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        contentStack.addArrangedSubview(footer)
    }

    private func makeHeader() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2

        let identity = NSStackView()
        identity.orientation = .horizontal
        identity.spacing = 6
        identity.alignment = .centerY

        let icon = NSImageView()
        if let image = NSImage(
            systemSymbolName: "chart.bar.doc.horizontal",
            accessibilityDescription: "CursorGauge"
        ) {
            icon.image = image
            icon.contentTintColor = .secondaryLabelColor
            icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        }
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        identity.addArrangedSubview(icon)
        identity.addArrangedSubview(titleLabel)

        remainingLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        remainingLabel.textColor = .labelColor
        remainingLabel.setAccessibilityLabel("Remaining allowance")

        updatedLabel.font = .systemFont(ofSize: 11)
        updatedLabel.textColor = .tertiaryLabelColor

        statusMessageLabel.font = .systemFont(ofSize: 11)
        statusMessageLabel.textColor = .secondaryLabelColor
        statusMessageLabel.isHidden = true

        stack.addArrangedSubview(identity)
        stack.addArrangedSubview(spacer(4))
        stack.addArrangedSubview(remainingLabel)
        stack.addArrangedSubview(updatedLabel)
        stack.addArrangedSubview(statusMessageLabel)
        stack.addArrangedSubview(spacer(4))
        return stack
    }

    private func makeIncludedSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4

        stack.addArrangedSubview(sectionHeader("Included", symbol: "creditcard"))
        styleSecondary(includedUsedLabel)
        styleSecondary(includedLimitLabel)
        styleSecondary(includedRemainingLabel)
        stack.addArrangedSubview(includedUsedLabel)
        stack.addArrangedSubview(includedLimitLabel)
        stack.addArrangedSubview(includedRemainingLabel)

        includedProgress.isIndeterminate = false
        includedProgress.style = .bar
        includedProgress.minValue = 0
        includedProgress.maxValue = 1
        includedProgress.controlSize = .small
        includedProgress.translatesAutoresizingMaskIntoConstraints = false
        includedProgress.heightAnchor.constraint(equalToConstant: 12).isActive = true
        includedProgress.widthAnchor.constraint(equalToConstant: Self.popoverWidth - 40).isActive = true
        stack.addArrangedSubview(spacer(2))
        stack.addArrangedSubview(includedProgress)
        return stack
    }

    private func configureOnDemandSection() {
        onDemandSection.orientation = .vertical
        onDemandSection.alignment = .leading
        onDemandSection.spacing = 4
        onDemandSection.isHidden = true

        onDemandSection.addArrangedSubview(sectionHeader("On-demand", symbol: "bolt"))
        styleSecondary(onDemandUsedLabel)
        styleSecondary(onDemandLimitLabel)
        styleSecondary(onDemandRemainingLabel)
        onDemandSection.addArrangedSubview(onDemandUsedLabel)
        onDemandSection.addArrangedSubview(onDemandLimitLabel)
        onDemandSection.addArrangedSubview(onDemandRemainingLabel)

        onDemandProgress.isIndeterminate = false
        onDemandProgress.style = .bar
        onDemandProgress.minValue = 0
        onDemandProgress.maxValue = 1
        onDemandProgress.controlSize = .small
        onDemandProgress.translatesAutoresizingMaskIntoConstraints = false
        onDemandProgress.heightAnchor.constraint(equalToConstant: 12).isActive = true
        onDemandProgress.widthAnchor.constraint(equalToConstant: Self.popoverWidth - 40).isActive = true
        onDemandSection.addArrangedSubview(spacer(2))
        onDemandSection.addArrangedSubview(onDemandProgress)
    }

    private func makeStatsSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.addArrangedSubview(autoRow)
        stack.addArrangedSubview(apiRow)
        stack.addArrangedSubview(totalRow)
        stack.addArrangedSubview(resetRow)
        for row in [autoRow, apiRow, totalRow, resetRow] {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalToConstant: Self.popoverWidth - 28).isActive = true
        }
        return stack
    }

    private func makeModelsSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4

        modelsDisclosure.setButtonType(.pushOnPushOff)
        modelsDisclosure.bezelStyle = .disclosure
        modelsDisclosure.title = ""
        modelsDisclosure.setAccessibilityLabel("Models")
        modelsDisclosure.target = self
        modelsDisclosure.action = #selector(modelsDisclosureToggled)

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        let title = NSTextField(labelWithString: "Models")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        modelsSummaryLabel.font = .systemFont(ofSize: 11)
        modelsSummaryLabel.textColor = .secondaryLabelColor
        header.addArrangedSubview(modelsDisclosure)
        header.addArrangedSubview(title)
        header.addArrangedSubview(modelsSummaryLabel)

        modelsDisclaimer.font = .systemFont(ofSize: 10)
        modelsDisclaimer.textColor = .tertiaryLabelColor
        modelsDisclaimer.isHidden = true

        modelsStatusLabel.font = .systemFont(ofSize: 11)
        modelsStatusLabel.textColor = .secondaryLabelColor

        modelsListStack.orientation = .vertical
        modelsListStack.alignment = .leading
        modelsListStack.spacing = 6
        modelsListStack.isHidden = true

        modelsContainer.orientation = .vertical
        modelsContainer.alignment = .leading
        modelsContainer.spacing = 4
        modelsContainer.isHidden = true
        modelsContainer.addArrangedSubview(modelsStatusLabel)
        modelsContainer.addArrangedSubview(modelsListStack)

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(modelsDisclaimer)
        stack.addArrangedSubview(modelsContainer)
        return stack
    }

    private func makeSettingsSection() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4

        settingsDisclosure.setButtonType(.pushOnPushOff)
        settingsDisclosure.bezelStyle = .disclosure
        settingsDisclosure.title = ""
        settingsDisclosure.setAccessibilityLabel("Settings")
        settingsDisclosure.target = self
        settingsDisclosure.action = #selector(settingsDisclosureToggled)

        let header = NSStackView()
        header.orientation = .horizontal
        header.spacing = 6
        header.alignment = .centerY
        let gear = NSImageView()
        if let image = NSImage(
            systemSymbolName: "gearshape",
            accessibilityDescription: "Settings"
        ) {
            gear.image = image
            gear.contentTintColor = .secondaryLabelColor
            gear.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        }
        let title = NSTextField(labelWithString: "Settings")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        header.addArrangedSubview(settingsDisclosure)
        header.addArrangedSubview(gear)
        header.addArrangedSubview(title)

        settingsContainer.orientation = .vertical
        settingsContainer.alignment = .leading
        settingsContainer.spacing = 8
        settingsContainer.isHidden = true

        let displayTitle = NSTextField(labelWithString: "Menu bar display")
        displayTitle.font = .systemFont(ofSize: 11, weight: .medium)
        settingsContainer.addArrangedSubview(displayTitle)

        displayModeButtons = StatusDisplayMode.allCases.map { mode in
            let button = NSButton(
                radioButtonWithTitle: mode.settingsLabel,
                target: self,
                action: #selector(displayModeClicked(_:))
            )
            button.tag = modeTag(mode)
            button.font = .systemFont(ofSize: 12)
            button.setAccessibilityLabel(mode.settingsLabel)
            return button
        }
        for button in displayModeButtons {
            settingsContainer.addArrangedSubview(button)
        }

        launchAtLoginCheckbox.target = self
        launchAtLoginCheckbox.action = #selector(launchAtLoginToggled)
        launchAtLoginCheckbox.font = .systemFont(ofSize: 12)
        launchAtLoginCheckbox.setAccessibilityLabel("Launch at Login")
        settingsContainer.addArrangedSubview(spacer(4))
        settingsContainer.addArrangedSubview(launchAtLoginCheckbox)

        launchStatusLabel.font = .systemFont(ofSize: 11)
        launchStatusLabel.textColor = .secondaryLabelColor
        launchHintLabel.font = .systemFont(ofSize: 10)
        launchHintLabel.textColor = .tertiaryLabelColor
        settingsContainer.addArrangedSubview(launchStatusLabel)
        settingsContainer.addArrangedSubview(launchHintLabel)

        let privacy = NSTextField(
            wrappingLabelWithString:
                "No tokens, cookies, or spending history are written to disk by this app."
        )
        privacy.font = .systemFont(ofSize: 10)
        privacy.textColor = .tertiaryLabelColor
        settingsContainer.addArrangedSubview(privacy)

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(settingsContainer)
        return stack
    }

    private func makeActionRow(
        title: String,
        symbol: String,
        accessibility: String,
        action: Selector
    ) -> NSView {
        let button = HoverMenuButton()
        button.rowTitle = title
        button.symbolName = symbol
        button.target = self
        button.action = action
        button.setAccessibilityLabel(accessibility)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: Self.popoverWidth - 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return button
    }

    // MARK: - Helpers

    private func sectionHeader(_ title: String, symbol: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        let icon = NSImageView()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            icon.image = image
            icon.contentTintColor = .secondaryLabelColor
            icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        }
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        return row
    }

    private func makeSeparator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 1).isActive = true
        box.widthAnchor.constraint(equalToConstant: Self.popoverWidth - 28).isActive = true
        let wrap = NSStackView(views: [spacer(8), box, spacer(8)])
        wrap.orientation = .vertical
        wrap.alignment = .leading
        wrap.spacing = 0
        return wrap
    }

    private func spacer(_ height: CGFloat) -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    private func styleSecondary(_ label: NSTextField) {
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
    }

    private func configureProgress(
        _ indicator: NSProgressIndicator,
        used: Double,
        limit: Double,
        label: String
    ) {
        let fraction = usageProgressFraction(used: used, limit: limit)
        indicator.doubleValue = fraction
        indicator.setAccessibilityLabel(label)
        indicator.setAccessibilityValue("\(Int((fraction * 100).rounded())) percent used")
    }

    private func setMetricSectionsVisible(_ visible: Bool) {
        // Keep structure; values already updated. On error/loading we hide on-demand.
        if !visible {
            onDemandSection.isHidden = true
        }
    }

    private func rebuildModelRows(_ rows: [ModelUsageAggregate]) {
        clearArranged(modelsListStack)
        for row in rows {
            modelsListStack.addArrangedSubview(ModelRowView(aggregate: row))
        }
    }

    private func clearArranged(_ stack: NSStackView) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    private func modeTag(_ mode: StatusDisplayMode) -> Int {
        switch mode {
        case .dollarsRemaining: return 0
        case .percentRemaining: return 1
        }
    }

    private func modeFromTag(_ tag: Int) -> StatusDisplayMode {
        tag == 1 ? .percentRemaining : .dollarsRemaining
    }

    private func syncLaunchAtLoginUI(errorMessage: String? = nil) {
        let state = LaunchAtLogin.displayState
        launchAtLoginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
        if let errorMessage, !errorMessage.isEmpty {
            launchStatusLabel.stringValue = errorMessage
            launchStatusLabel.textColor = .systemRed
        } else {
            launchStatusLabel.stringValue = formatLaunchAtLoginStatus(state)
            launchStatusLabel.textColor = .secondaryLabelColor
        }
        launchHintLabel.stringValue = formatLaunchAtLoginLimitation(
            isInApplications: LaunchAtLogin.isBundledInApplications
        )
    }

    private func relayout() {
        view.layoutSubtreeIfNeeded()
        let fitting = contentStack.fittingSize
        let height = min(
            Self.maxContentHeight,
            max(Self.minContentHeight, fitting.height + 8)
        )
        let size = NSSize(width: Self.popoverWidth, height: height)
        preferredContentSize = size
        hostingPopover?.contentSize = size
    }

    // MARK: - Actions

    @objc private func refreshClicked() {
        delegate?.popoverDidRequestRefresh()
    }

    @objc private func dashboardClicked() {
        delegate?.popoverDidRequestOpenDashboard()
    }

    @objc private func quitClicked() {
        delegate?.popoverDidRequestQuit()
    }

    @objc private func displayModeClicked(_ sender: NSButton) {
        let mode = modeFromTag(sender.tag)
        syncDisplayMode(mode)
        delegate?.popoverDidChangeDisplayMode(mode)
    }

    @objc private func modelsDisclosureToggled() {
        modelsExpanded = modelsDisclosure.state == .on
        modelsContainer.isHidden = !modelsExpanded
        modelsListStack.isHidden = !modelsExpanded || modelsListStack.arrangedSubviews.isEmpty
        relayout()
    }

    @objc private func settingsDisclosureToggled() {
        settingsExpanded = settingsDisclosure.state == .on
        settingsContainer.isHidden = !settingsExpanded
        if settingsExpanded {
            syncLaunchAtLoginUI()
        }
        relayout()
    }

    @objc private func launchAtLoginToggled() {
        let wantEnabled = launchAtLoginCheckbox.state == .on
        do {
            try LaunchAtLogin.setEnabled(wantEnabled)
            syncLaunchAtLoginUI()
        } catch {
            syncLaunchAtLoginUI(errorMessage: LaunchAtLogin.sanitizedErrorMessage(error))
            // Revert checkbox to actual registration state.
            launchAtLoginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
        }
        relayout()
    }
}

// MARK: - Supporting views

@MainActor
private final class MetricRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "—")

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .labelColor
        valueLabel.font = .systemFont(ofSize: 12)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor,
                constant: 12
            ),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { nil }

    func setValue(_ value: String) {
        valueLabel.stringValue = value
        setAccessibilityValue(value)
    }
}

@MainActor
private final class ModelRowView: NSView {
    init(aggregate: ModelUsageAggregate) {
        super.init(frame: .zero)
        let name = NSTextField(labelWithString: aggregate.model)
        name.font = .systemFont(ofSize: 12, weight: .medium)
        name.lineBreakMode = .byTruncatingTail

        let detail = NSTextField(wrappingLabelWithString: formatModelRowDetail(aggregate))
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [name, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(aggregate.model)
        setAccessibilityValue(formatModelRowDetail(aggregate))
    }

    required init?(coder: NSCoder) { nil }
}

/// Compact menu-like row with light hover highlight (no Accessibility permissions required).
@MainActor
private final class HoverMenuButton: NSControl {
    var symbolName: String = "circle" {
        didSet { refresh() }
    }

    var rowTitle: String = "" {
        didSet { refresh() }
    }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var hovered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6

        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.isEditable = false
        titleLabel.isBordered = false
        titleLabel.drawsBackground = false
        titleLabel.font = .systemFont(ofSize: 12)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        addSubview(iconView)
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    private func refresh() {
        if let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: rowTitle
        ) {
            iconView.image = image
            iconView.contentTintColor = .secondaryLabelColor
            iconView.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        }
        titleLabel.stringValue = rowTitle
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking {
            removeTrackingArea(tracking)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.14).cgColor
    }

    override func mouseUp(with event: NSEvent) {
        layer?.backgroundColor =
            hovered
            ? NSColor.labelColor.withAlphaComponent(0.08).cgColor
            : NSColor.clear.cgColor
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            sendAction(action, to: target)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { // Return / Space
            sendAction(action, to: target)
        } else {
            super.keyDown(with: event)
        }
    }
}
