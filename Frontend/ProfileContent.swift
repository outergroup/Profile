import AppKit
import CoreText
import Foundation
import QuartzCore

@MainActor
@objc public final class ProfileContent: NSObject, OuterframeContentLibrary {
    @objc public static func start(socketFD: Int32, appConnection: OuterframeAppConnection) -> Int32 {
        let outerframeHost = OuterframeHost(socketFD: socketFD)
        let handler = ProfileHandler(outerframeHost: outerframeHost, appConnection: appConnection)
        outerframeHost.delegate = handler
        return 0
    }
}

private struct ProcessListResponse {
    let processes: [ProfileProcess]
}

private struct RecordingStartResponse {
    let recordingID: UInt64
    let pid: Int
    let frequency: Int
    let recording: Bool
}

private struct ProfileListResponse {
    let recording: Bool
    let recordingID: UInt64
    let profiles: [ProfileSummary]
}

private struct ProfileSummary {
    let profileID: UInt64
    let pid: Int
    let duration: Double
    let frequency: Int
    let sampleCount: Int
    let cpuMilliseconds: Double
    let status: String?
}

private struct ProfileProcess {
    let pid: Int
    let ppid: Int
    let name: String
    let command: String
}

private struct ProfileResponse {
    let profileID: UInt64
    let pid: Int
    let duration: Int
    let frequency: Int
    let cpuMilliseconds: Double
    let rangeStart: Double
    let rangeEnd: Double
    let sampleCount: Int
    let totalSampleCount: Int
    let aggregateCount: Int
    let recordStatus: Int
    let scriptStatus: Int
    let parsed: Bool
    let status: String?
    let recordOutput: String
    let scriptError: String
    let timeline: [TimelineBucket]
    let folded: [FoldedStack]
}

private struct TimelineBucket {
    let start: Double
    let end: Double
    let samples: Int
    let cpuPercent: Double
}

private struct FoldedStack {
    let count: Int
    let stack: [StackFrame]
}

private struct StackFrame: Hashable {
    let symbol: String
    let binary: String

    init(symbol: String, binary: String) {
        self.symbol = symbol
        self.binary = binary
    }

}

private final class FlameNode {
    let frame: StackFrame
    var count: Int = 0
    var children: [StackFrame: FlameNode] = [:]

    init(frame: StackFrame) {
        self.frame = frame
    }

    func child(frame: StackFrame) -> FlameNode {
        if let existing = children[frame] {
            return existing
        }
        let node = FlameNode(frame: frame)
        children[frame] = node
        return node
    }
}

private struct FlameHitRegion {
    let frame: CGRect
    let symbol: String
    let binary: String
    let count: Int
    let depth: Int
    let total: Int
}

private final class FlameLayerItem {
    let node: FlameNode
    let depth: Int
    let xFraction: CGFloat
    let widthFraction: CGFloat
    let boxLayer: CALayer
    var symbolClipLayer: CALayer?
    var symbolLayer: CATextLayer?
    var binaryClipLayer: CALayer?
    var binaryLayer: CATextLayer?
    var frame: CGRect = .zero

    init(node: FlameNode, depth: Int, xFraction: CGFloat, widthFraction: CGFloat, boxLayer: CALayer) {
        self.node = node
        self.depth = depth
        self.xFraction = xFraction
        self.widthFraction = widthFraction
        self.boxLayer = boxLayer
    }
}

private struct BinaryReader {
    let data: Data

    func u32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(data[offset + index]) << UInt32(index * 8)
        }
        return value
    }

    func i32(at offset: Int) -> Int32? {
        u32(at: offset).map { Int32(bitPattern: $0) }
    }

    func u64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        var value: UInt64 = 0
        for index in 0..<8 {
            value |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
        return value
    }

    func f64(at offset: Int) -> Double? {
        guard let bits = u64(at: offset) else { return nil }
        return Double(bitPattern: bits)
    }

    func string(offset: UInt32, length: UInt32) -> String? {
        let start = Int(offset)
        let count = Int(length)
        guard start >= 0, count >= 0, start + count <= data.count else { return nil }
        return String(data: data.subdata(in: start..<(start + count)), encoding: .utf8) ?? ""
    }
}

private enum ProfileBinary {
    private static let magic = [UInt8(ascii: "P"), UInt8(ascii: "R"), UInt8(ascii: "F"), UInt8(ascii: "L")]
    private static let version: UInt32 = 1
    private static let processesType: UInt32 = 1
    private static let profileListType: UInt32 = 2
    private static let recordingType: UInt32 = 3
    private static let profileType: UInt32 = 4

    private static func reader(_ data: Data, type expectedType: UInt32) -> BinaryReader? {
        guard data.count >= 16 else { return nil }
        guard Array(data[0..<4]) == magic else { return nil }
        let reader = BinaryReader(data: data)
        guard reader.u32(at: 4) == version, reader.u32(at: 8) == expectedType else { return nil }
        return reader
    }

    static func decodeProcesses(_ data: Data) -> ProcessListResponse? {
        guard let reader = reader(data, type: processesType),
              let count = reader.u32(at: 16),
              let rowsOffset = reader.u32(at: 20) else { return nil }
        var processes: [ProfileProcess] = []
        for index in 0..<Int(count) {
            let row = Int(rowsOffset) + index * 24
            guard let pid = reader.i32(at: row),
                  let ppid = reader.i32(at: row + 4),
                  let nameOffset = reader.u32(at: row + 8),
                  let nameLength = reader.u32(at: row + 12),
                  let commandOffset = reader.u32(at: row + 16),
                  let commandLength = reader.u32(at: row + 20),
                  let name = reader.string(offset: nameOffset, length: nameLength),
                  let command = reader.string(offset: commandOffset, length: commandLength) else { return nil }
            processes.append(ProfileProcess(pid: Int(pid), ppid: Int(ppid), name: name, command: command))
        }
        return ProcessListResponse(processes: processes)
    }

    static func decodeRecording(_ data: Data) -> RecordingStartResponse? {
        guard let reader = reader(data, type: recordingType),
              let recording = reader.u32(at: 16),
              let recordingID = reader.u64(at: 20),
              let pid = reader.i32(at: 28),
              let frequency = reader.i32(at: 32) else { return nil }
        return RecordingStartResponse(recordingID: recordingID,
                                      pid: Int(pid),
                                      frequency: Int(frequency),
                                      recording: recording != 0)
    }

    static func decodeProfileList(_ data: Data) -> ProfileListResponse? {
        guard let reader = reader(data, type: profileListType),
              let recording = reader.u32(at: 16),
              let recordingID = reader.u64(at: 20),
              let count = reader.u32(at: 28),
              let rowsOffset = reader.u32(at: 32) else { return nil }
        var profiles: [ProfileSummary] = []
        for index in 0..<Int(count) {
            let row = Int(rowsOffset) + index * 48
            guard let profileID = reader.u64(at: row),
                  let pid = reader.i32(at: row + 8),
                  let frequency = reader.i32(at: row + 12),
                  let sampleCount = reader.u32(at: row + 16),
                  let duration = reader.f64(at: row + 24),
                  let cpuMilliseconds = reader.f64(at: row + 32),
                  let statusOffset = reader.u32(at: row + 40),
                  let statusLength = reader.u32(at: row + 44),
                  let status = reader.string(offset: statusOffset, length: statusLength) else { return nil }
            profiles.append(ProfileSummary(profileID: profileID,
                                           pid: Int(pid),
                                           duration: duration,
                                           frequency: Int(frequency),
                                           sampleCount: Int(sampleCount),
                                           cpuMilliseconds: cpuMilliseconds,
                                           status: status))
        }
        return ProfileListResponse(recording: recording != 0, recordingID: recordingID, profiles: profiles)
    }

    static func decodeProfile(_ data: Data) -> ProfileResponse? {
        guard let reader = reader(data, type: profileType),
              let profileID = reader.u64(at: 16),
              let pid = reader.i32(at: 24),
              let duration = reader.i32(at: 28),
              let frequency = reader.i32(at: 32),
              let parsed = reader.u32(at: 36),
              let cpuMilliseconds = reader.f64(at: 40),
              let rangeStart = reader.f64(at: 48),
              let rangeEnd = reader.f64(at: 56),
              let sampleCount = reader.u32(at: 64),
              let totalSampleCount = reader.u32(at: 68),
              let aggregateCount = reader.u32(at: 72),
              let recordStatus = reader.i32(at: 76),
              let scriptStatus = reader.i32(at: 80),
              let statusOffset = reader.u32(at: 84),
              let statusLength = reader.u32(at: 88),
              let recordOutputOffset = reader.u32(at: 92),
              let recordOutputLength = reader.u32(at: 96),
              let scriptErrorOffset = reader.u32(at: 100),
              let scriptErrorLength = reader.u32(at: 104),
              let timelineCount = reader.u32(at: 108),
              let timelineOffset = reader.u32(at: 112),
              let foldedCount = reader.u32(at: 116),
              let foldedOffset = reader.u32(at: 120),
              let frameCount = reader.u32(at: 124),
              let framesOffset = reader.u32(at: 128),
              let status = reader.string(offset: statusOffset, length: statusLength),
              let recordOutput = reader.string(offset: recordOutputOffset, length: recordOutputLength),
              let scriptError = reader.string(offset: scriptErrorOffset, length: scriptErrorLength) else { return nil }

        var timeline: [TimelineBucket] = []
        for index in 0..<Int(timelineCount) {
            let row = Int(timelineOffset) + index * 32
            guard let start = reader.f64(at: row),
                  let end = reader.f64(at: row + 8),
                  let cpuPercent = reader.f64(at: row + 16),
                  let samples = reader.u32(at: row + 24) else { return nil }
            timeline.append(TimelineBucket(start: start, end: end, samples: Int(samples), cpuPercent: cpuPercent))
        }

        var frames: [StackFrame] = []
        for index in 0..<Int(frameCount) {
            let row = Int(framesOffset) + index * 16
            guard let symbolOffset = reader.u32(at: row),
                  let symbolLength = reader.u32(at: row + 4),
                  let binaryOffset = reader.u32(at: row + 8),
                  let binaryLength = reader.u32(at: row + 12),
                  let symbol = reader.string(offset: symbolOffset, length: symbolLength),
                  let binary = reader.string(offset: binaryOffset, length: binaryLength) else { return nil }
            frames.append(StackFrame(symbol: symbol, binary: binary))
        }

        var folded: [FoldedStack] = []
        for index in 0..<Int(foldedCount) {
            let row = Int(foldedOffset) + index * 12
            guard let count = reader.u32(at: row),
                  let depth = reader.u32(at: row + 4),
                  let firstFrame = reader.u32(at: row + 8) else { return nil }
            let start = Int(firstFrame)
            let end = start + Int(depth)
            guard start >= 0, end <= frames.count else { return nil }
            folded.append(FoldedStack(count: Int(count), stack: Array(frames[start..<end])))
        }

        return ProfileResponse(profileID: profileID,
                               pid: Int(pid),
                               duration: Int(duration),
                               frequency: Int(frequency),
                               cpuMilliseconds: cpuMilliseconds,
                               rangeStart: rangeStart,
                               rangeEnd: rangeEnd,
                               sampleCount: Int(sampleCount),
                               totalSampleCount: Int(totalSampleCount),
                               aggregateCount: Int(aggregateCount),
                               recordStatus: Int(recordStatus),
                               scriptStatus: Int(scriptStatus),
                               parsed: parsed != 0,
                               status: status,
                               recordOutput: recordOutput,
                               scriptError: scriptError,
                               timeline: timeline,
                               folded: folded)
    }
}

@MainActor
private final class ProfileHandler: NSObject, OuterframeHostDelegate {
    private let outerframeHost: OuterframeHost
    private let appConnection: OuterframeAppConnection
    private var retainedSelf: ProfileHandler?

    private let rootLayer = CALayer()
    private let toolbarLayer = CALayer()
    private let sidebarLayer = CALayer()
    private let processListLayer = CALayer()
    private let processChromeLayer = CALayer()
    private let processSearchLayer = CALayer()
    private let processSearchIconLayer = CALayer()
    private let processSearchTextLayer = CATextLayer()
    private let processSearchPlaceholderLayer = CATextLayer()
    private let processSearchSelectionLayer = CALayer()
    private let processSearchCursorLayer = CALayer()
    private let processViewportLayer = CALayer()
    private let processContentLayer = CALayer()
    private let processScrollbarLayer = CALayer()
    private let traceViewportLayer = CALayer()
    private let traceContentLayer = CALayer()
    private let traceScrollbarLayer = CALayer()
    private let timelineLayer = CALayer()
    private let flameLayer = CALayer()
    private let flameDecorationLayer = CALayer()
    private let flameViewportLayer = CALayer()
    private let flameBoxContentLayer = CALayer()
    private let flameTextOverlayLayer = CALayer()
    private let flameScrollbarLayer = CALayer()
    private let statusLayer = CATextLayer()
    private let refreshButtonLayer = CALayer()
    private let recordToggleButtonLayer = CALayer()
    private let tooltipLayer = CALayer()
    private let tooltipTextLayer = CATextLayer()

    private var currentSize = CGSize(width: 1100, height: 720)
    private var appearance = NSAppearance.currentDrawing()
    private var urlSession: URLSession?
    private var processesEndpoint: URL?
    private var profileStartEndpoint: URL?
    private var profileStopEndpoint: URL?
    private var profileListEndpoint: URL?
    private var profileRangeEndpoint: URL?
    private var profileDeleteEndpoint: URL?
    private var hasRegisteredLayer = false

    private var traces: [ProfileSummary] = []
    private var processes: [ProfileProcess] = []
    private var selectedTraceID: UInt64?
    private var selectedPID: Int?
    private var processScroll: CGFloat = 0
    private var traceScroll: CGFloat = 0
    private var processSearchText = ""
    private var processSearchCursorPosition = 0
    private var processSearchSelectionAnchor: Int?
    private var processSearchFocused = false
    private var filteredProcessIndices: [Int] = []
    private var showingSetup = true
    private var isBusy = false
    private var isRecording = false
    private var activeRecordingID: UInt64?
    private var activeRecordingPID: Int?
    private var activeRecordingFrequency: Int?
    private var recordingStartedAt: Date?
    private var isFetchingRange = false
    private var lastProfile: ProfileResponse?
    private var selectedRange: ClosedRange<Double>?
    private var rangeDragStart: Double?
    private var flameHitRegions: [FlameHitRegion] = []
    private var flameLayerItems: [FlameLayerItem] = []
    private var flameTotalSamples = 0
    private var flameVerticalScroll: CGFloat = 0
    private var flameHorizontalScroll: CGFloat = 0
    private var flameZoom: CGFloat = 1
    private var flameLaidOutZoom: CGFloat = 1
    private var flameContentSize = CGSize.zero
    private var traceContextMenuTargets: [UUID: UInt64] = [:]
    private var processSearchContextMenuIDs: Set<UUID> = []

    private let toolbarHeight: CGFloat = 52
    private let sidebarWidth: CGFloat = 240
    private let timelineHeight: CGFloat = 132
    private let rowHeight: CGFloat = 30
    private let runRowHeight: CGFloat = 56
    private let horizontalInset: CGFloat = 14
    private static let processSearchFieldID = UUID()
    private let processSearchCaretBlinkAnimationKey = "processSearchCaretBlink"

    init(outerframeHost: OuterframeHost, appConnection: OuterframeAppConnection) {
        self.outerframeHost = outerframeHost
        self.appConnection = appConnection
        super.init()
        self.retainedSelf = self
    }

    func outerframeHost(_ host: OuterframeHost, didReceiveMessage message: BrowserToContentMessage) {
        switch message {
        case .initializeContent(let arguments):
            outerframeHost.configure(url: arguments.url ?? "",
                                     bundleUrl: arguments.bundleUrl ?? "",
                                     proxyHost: arguments.proxy?.host,
                                     proxyPort: arguments.proxy?.port ?? 0,
                                     proxyUsername: arguments.proxy?.username,
                                     proxyPassword: arguments.proxy?.password)
            appearance = arguments.appearance ?? appearance
            currentSize = arguments.contentSize ?? currentSize
            configureNetworking()
            configureLayersIfNeeded()
            updateColors()
            updateLayout()
            registerRootLayerIfNeeded()
            outerframeHost.setInputMode(.rawKeys)
            fetchProfiles(selectLatestIfNeeded: true)
            fetchProcesses()

        case .resizeContent(let size):
            currentSize = size
            clampProcessScroll()
            clampTraceScroll()
            updateLayout()

        case .systemAppearanceUpdate(let appearance):
            self.appearance = appearance
            updateColors()

        case .scrollWheelEvent(let point, let delta, _, _, _, let hasPreciseScrollingDeltas):
            let multiplier: CGFloat = hasPreciseScrollingDeltas ? 1 : rowHeight
            if showingSetup, processListLayer.frame.contains(point) {
                processScroll -= delta.y * multiplier
                clampProcessScroll()
                updateProcessScrollPosition()
            } else if sidebarLayer.frame.contains(point) {
                let sidebarPoint = sidebarLayer.convert(point, from: rootLayer)
                if traceViewportLayer.frame.contains(sidebarPoint) {
                    traceScroll -= delta.y * multiplier
                    clampTraceScroll()
                    updateTraceScrollPosition()
                }
            } else if !showingSetup, flameLayer.frame.contains(point) {
                flameHorizontalScroll -= delta.x * multiplier
                flameVerticalScroll -= delta.y * multiplier
                clampFlameScroll()
                hideTooltip()
                updateFlameScrollPosition()
            }

        case .magnification(_, let magnification, let location, _):
            handleMagnification(magnification, at: location)

        case .magnificationEnded(_, _, _, _):
            clampFlameScroll()
            commitFlameZoomLayout()
            updateFlameScrollPosition()

        case .mouseDown(let point, _, _):
            handleMouseDown(at: point)

        case .mouseDragged(let point, _):
            handleMouseDragged(at: point)

        case .mouseUp(let point, _):
            handleMouseUp(at: point)

        case .mouseMoved(let point, _):
            handleMouseMoved(at: point)

        case .keyDown(let keyCode, let characters, let charactersIgnoringModifiers, let modifierFlags, let isARepeat):
            handleKeyDown(keyCode: keyCode,
                          characters: characters,
                          charactersIgnoringModifiers: charactersIgnoringModifiers,
                          modifierFlags: modifierFlags,
                          isARepeat: isARepeat)

        case .textInput(let text, let hasReplacementRange, let replacementLocation, let replacementLength):
            handleTextInput(text,
                            hasReplacementRange: hasReplacementRange,
                            replacementLocation: replacementLocation,
                            replacementLength: replacementLength)

        case .textCommand(let command):
            handleTextCommand(command)

        case .textInputFocus(let fieldID, let hasFocus):
            handleTextInputFocus(fieldID: fieldID, hasFocus: hasFocus)

        case .setCursorPosition(let fieldID, let position, let modifySelection):
            handleSetCursorPosition(fieldID: fieldID, position: position, modifySelection: modifySelection)

        case .rightMouseDown(let point, _, _):
            handleRightMouseDown(at: point)

        case .contextMenuItemSelected(let menuID, let itemID):
            handleContextMenuSelection(menuID: menuID, itemID: itemID)

        case .selectionToPasteboardCopyRequest(let requestID):
            outerframeHost.sendCopySelectedPasteboardResponse(requestID: requestID,
                                                              items: processSearchPasteboardItems())

        case .selectionToPasteboardCutRequest(let requestID):
            let items = processSearchPasteboardItems()
            outerframeHost.sendCopySelectedPasteboardResponse(requestID: requestID,
                                                              items: items)
            if !items.isEmpty {
                deleteProcessSearchSelection()
            }

        case .pasteboardContentPasted(let items):
            insertProcessSearchPasteboardItems(items)

        case .accessibilitySnapshotRequest(let requestID):
            outerframeHost.sendAccessibilitySnapshotResponse(requestID: requestID, snapshot: nil)

        case .shutdown:
            retainedSelf = nil

        default:
            break
        }
    }

    func outerframeHostDidDisconnect(_ host: OuterframeHost) {
        retainedSelf = nil
    }

    private func configureNetworking() {
        guard let base = outerframeHost.pluginBaseURL() else { return }
        processesEndpoint = URL(string: "/api/processes", relativeTo: base)?.absoluteURL
        profileStartEndpoint = URL(string: "/api/profile/start", relativeTo: base)?.absoluteURL
        profileStopEndpoint = URL(string: "/api/profile/stop", relativeTo: base)?.absoluteURL
        profileListEndpoint = URL(string: "/api/profiles", relativeTo: base)?.absoluteURL
        profileRangeEndpoint = URL(string: "/api/profile/range", relativeTo: base)?.absoluteURL
        profileDeleteEndpoint = URL(string: "/api/profile/delete", relativeTo: base)?.absoluteURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        outerframeHost.applyProxy(to: configuration)
        urlSession = URLSession(configuration: configuration)
    }

    private func configureLayersIfNeeded() {
        guard toolbarLayer.superlayer == nil else { return }
        rootLayer.masksToBounds = true
        rootLayer.addSublayer(toolbarLayer)
        rootLayer.addSublayer(sidebarLayer)
        rootLayer.addSublayer(processListLayer)
        rootLayer.addSublayer(timelineLayer)
        rootLayer.addSublayer(flameLayer)
        rootLayer.addSublayer(statusLayer)
        rootLayer.addSublayer(tooltipLayer)

        processListLayer.addSublayer(processChromeLayer)
        processListLayer.addSublayer(processViewportLayer)
        processListLayer.addSublayer(processScrollbarLayer)
        processViewportLayer.masksToBounds = true
        processViewportLayer.addSublayer(processContentLayer)
        traceViewportLayer.masksToBounds = true
        traceViewportLayer.addSublayer(traceContentLayer)

        flameLayer.addSublayer(flameDecorationLayer)
        flameLayer.addSublayer(flameViewportLayer)
        flameLayer.addSublayer(flameScrollbarLayer)
        flameViewportLayer.masksToBounds = true
        flameViewportLayer.addSublayer(flameBoxContentLayer)
        flameViewportLayer.addSublayer(flameTextOverlayLayer)
        flameBoxContentLayer.anchorPoint = .zero
        flameTextOverlayLayer.anchorPoint = .zero

        toolbarLayer.addSublayer(refreshButtonLayer)
        refreshButtonLayer.addSublayer(makeButtonLabel("Refresh"))

        processSearchLayer.addSublayer(processSearchIconLayer)
        processSearchLayer.addSublayer(processSearchSelectionLayer)
        processSearchLayer.addSublayer(processSearchPlaceholderLayer)
        processSearchLayer.addSublayer(processSearchTextLayer)
        processSearchLayer.addSublayer(processSearchCursorLayer)
        let processSearchNoActions = noImplicitLayerActions()
        processSearchLayer.actions = processSearchNoActions
        processSearchIconLayer.actions = processSearchNoActions
        processSearchPlaceholderLayer.actions = processSearchNoActions
        processSearchTextLayer.actions = processSearchNoActions
        processSearchSelectionLayer.actions = processSearchNoActions
        processSearchCursorLayer.actions = processSearchNoActions
        processSearchPlaceholderLayer.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        processSearchPlaceholderLayer.fontSize = 13
        processSearchPlaceholderLayer.contentsScale = 2
        processSearchPlaceholderLayer.truncationMode = .end
        processSearchPlaceholderLayer.string = "Search processes"
        processSearchTextLayer.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        processSearchTextLayer.fontSize = 13
        processSearchTextLayer.contentsScale = 2
        processSearchTextLayer.truncationMode = .end
        processSearchCursorLayer.cornerRadius = 0.5

        statusLayer.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        statusLayer.fontSize = 13
        statusLayer.contentsScale = 2
        statusLayer.truncationMode = .end
        statusLayer.alignmentMode = .left
        statusLayer.string = "Choose a process for the next recording."

        tooltipLayer.cornerRadius = 6
        tooltipLayer.borderWidth = 1
        tooltipLayer.shadowOpacity = 0.16
        tooltipLayer.shadowRadius = 12
        tooltipLayer.shadowOffset = CGSize(width: 0, height: -3)
        tooltipLayer.isHidden = true
        tooltipLayer.addSublayer(tooltipTextLayer)
        tooltipTextLayer.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        tooltipTextLayer.fontSize = 12
        tooltipTextLayer.contentsScale = 2
        tooltipTextLayer.alignmentMode = .left
        tooltipTextLayer.truncationMode = .end
        tooltipTextLayer.isWrapped = true
    }

    private func registerRootLayerIfNeeded() {
        guard !hasRegisteredLayer, let registerLayer = appConnection.registerLayer else { return }
        registerLayer(rootLayer)
        hasRegisteredLayer = true
    }

    private func updateColors() {
        appearance.performAsCurrentDrawingAppearance {
            rootLayer.backgroundColor = NSColor.windowBackgroundColor.cgColor
            toolbarLayer.backgroundColor = toolbarColor.cgColor
            sidebarLayer.backgroundColor = sidebarBackgroundColor.cgColor
            processListLayer.backgroundColor = NSColor.windowBackgroundColor.cgColor
            processSearchLayer.backgroundColor = searchFieldBackgroundColor.cgColor
            processSearchLayer.borderColor = (processSearchFocused ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor).cgColor
            processSearchLayer.borderWidth = processSearchFocused ? 1.5 : 1
            processSearchPlaceholderLayer.foregroundColor = NSColor.placeholderTextColor.cgColor
            processSearchTextLayer.foregroundColor = NSColor.labelColor.cgColor
            processSearchSelectionLayer.backgroundColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(isDarkMode ? 0.58 : 0.42).cgColor
            processSearchCursorLayer.backgroundColor = NSColor.labelColor.cgColor
            updateSymbolLayer(processSearchIconLayer, symbolName: "magnifyingglass", color: NSColor.secondaryLabelColor)
            timelineLayer.backgroundColor = NSColor.windowBackgroundColor.cgColor
            flameLayer.backgroundColor = NSColor.windowBackgroundColor.cgColor
            statusLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
            tooltipLayer.backgroundColor = tooltipBackgroundColor.cgColor
            tooltipLayer.borderColor = NSColor.separatorColor.cgColor
            tooltipTextLayer.foregroundColor = NSColor.labelColor.cgColor
            refreshButtonLayer.isHidden = !showingSetup
            styleButton(refreshButtonLayer, enabled: showingSetup && !isBusy && !isRecording)
            styleRecordButton()
        }
        updateSidebar()
        updateProcessRows()
        updateTimeline()
        updateFlameGraph()
    }

    private func updateLayout() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let width = max(currentSize.width, 1)
        let height = max(currentSize.height, 1)
        let sidebarWidth = min(self.sidebarWidth, max(width * 0.38, 180))
        rootLayer.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        toolbarLayer.frame = CGRect(x: sidebarWidth, y: height - toolbarHeight, width: max(width - sidebarWidth, 1), height: toolbarHeight)
        sidebarLayer.frame = CGRect(x: 0, y: 0, width: sidebarWidth, height: height)

        let contentX = sidebarWidth
        let contentHeight = max(height - toolbarHeight, 1)
        let contentWidth = max(width - contentX, 1)
        processListLayer.frame = CGRect(x: contentX, y: 0, width: contentWidth, height: contentHeight)
        processChromeLayer.frame = processListLayer.bounds
        processScrollbarLayer.frame = processListLayer.bounds
        timelineLayer.frame = CGRect(x: contentX,
                                     y: max(contentHeight - timelineHeight, 0),
                                     width: contentWidth,
                                     height: min(timelineHeight, contentHeight))
        flameLayer.frame = CGRect(x: contentX, y: 0, width: contentWidth, height: max(contentHeight - timelineLayer.frame.height, 1))

        recordToggleButtonLayer.frame = CGRect(x: sidebarWidth - 50, y: height - toolbarHeight + 11, width: 34, height: 30)
        refreshButtonLayer.frame = CGRect(x: horizontalInset, y: 11, width: 84, height: 30)
        refreshButtonLayer.isHidden = !showingSetup
        let statusX = showingSetup ? contentX + 112 : contentX + horizontalInset
        let statusRightInset: CGFloat = showingSetup ? 16 : horizontalInset
        statusLayer.frame = CGRect(x: statusX, y: height - 35, width: max(width - statusX - statusRightInset, 1), height: 18)
        refreshButtonLayer.sublayers?.first?.frame = refreshButtonLayer.bounds.insetBy(dx: 10, dy: 6)
        CATransaction.commit()

        clampProcessScroll()
        clampFlameScroll()
        updateSidebar()
        updateProcessRows()
        updateTimeline()
        updateFlameGraph()
    }

    private func handleMouseDown(at point: CGPoint) {
        let toolbarPoint = toolbarLayer.convert(point, from: rootLayer)
        if showingSetup, refreshButtonLayer.frame.contains(toolbarPoint), !isBusy, !isRecording {
            fetchProcesses()
            return
        }

        if sidebarLayer.frame.contains(point) {
            let sidebarPoint = sidebarLayer.convert(point, from: rootLayer)
            if recordToggleButtonLayer.frame.contains(sidebarPoint), !isBusy {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
                return
            }
            handleSidebarClick(at: sidebarPoint)
            return
        }

        if !showingSetup, timelineLayer.frame.contains(point), lastProfile != nil {
            let timelinePoint = timelineLayer.convert(point, from: rootLayer)
            if let time = timeForTimelinePoint(timelinePoint) {
                rangeDragStart = time
                selectedRange = time...time
                updateTimeline()
            }
            return
        }

        guard showingSetup, !isRecording else { return }
        let listPoint = processListLayer.convert(point, from: rootLayer)
        if processSearchFrame().contains(listPoint) {
            focusProcessSearch(cursorPosition: processSearchCursorPosition(at: listPoint), modifySelection: false)
            return
        }
        if processListLayer.bounds.contains(listPoint), !processSearchFrame().contains(listPoint) {
            blurProcessSearch()
        }
        let listFrame = processTableFrame()
        guard listFrame.contains(listPoint) else { return }
        let filteredIndex = Int(floor((listFrame.maxY - listPoint.y + processScroll) / rowHeight))
        if filteredProcessIndices.indices.contains(filteredIndex) {
            let process = processes[filteredProcessIndices[filteredIndex]]
            selectedPID = process.pid
            statusLayer.string = "Next recording target: \(process.name) (\(process.pid))."
            updateColors()
        }
    }

    private func handleSidebarClick(at point: CGPoint) {
        if nextRecordingFrame().contains(point) {
            showingSetup = true
            selectedTraceID = nil
            lastProfile = nil
            selectedRange = nil
            statusLayer.string = "Choose a process for the next recording."
            fetchProcesses()
            updateColors()
            return
        }

        if let index = traceIndex(at: point) {
            selectTrace(at: index)
        }
    }

    private func handleRightMouseDown(at point: CGPoint) {
        if showingSetup, processListLayer.frame.contains(point) {
            let listPoint = processListLayer.convert(point, from: rootLayer)
            if processSearchFrame().contains(listPoint) {
                focusProcessSearch(cursorPosition: processSearchCursorPosition(at: listPoint), modifySelection: false)
                showProcessSearchContextMenu(at: point)
                return
            }
        }

        guard sidebarLayer.frame.contains(point) else { return }
        let sidebarPoint = sidebarLayer.convert(point, from: rootLayer)
        guard let index = traceIndex(at: sidebarPoint) else { return }
        let trace = traces[index]
        let menuID = UUID()
        traceContextMenuTargets[menuID] = trace.profileID
        let items = [
            OuterframeContextMenuItem(id: "delete",
                                      title: "Delete Trace",
                                      systemImageName: "trash")
        ]
        outerframeHost.showContextMenu(menuID: menuID, items: items, at: point)
    }

    private func handleContextMenuSelection(menuID: UUID, itemID: String) {
        if processSearchContextMenuIDs.remove(menuID) != nil {
            handleProcessSearchContextMenuSelection(itemID: itemID)
            return
        }

        guard itemID == "delete",
              let profileID = traceContextMenuTargets.removeValue(forKey: menuID) else { return }
        deleteTrace(id: profileID)
    }

    private func traceIndex(at point: CGPoint) -> Int? {
        guard traceViewportLayer.frame.contains(point) else { return nil }
        let viewport = traceViewportLayer.bounds
        let contentHeight = max(CGFloat(traceRowCount()) * runRowHeight, viewport.height)
        let contentOffsetY = viewport.height - contentHeight + traceScroll
        let contentPoint = CGPoint(x: point.x - traceViewportLayer.frame.minX,
                                   y: point.y - traceViewportLayer.frame.minY - contentOffsetY)
        let visualIndex = Int(floor((contentHeight - contentPoint.y) / runRowHeight))
        guard visualIndex >= activeRecordingTraceRowCount(),
              visualIndex < traceRowCount(),
              traceFrame(visualIndex: visualIndex).contains(contentPoint) else {
            return nil
        }
        let traceVisualIndex = visualIndex - activeRecordingTraceRowCount()
        let index = traces.count - 1 - traceVisualIndex
        guard traces.indices.contains(index) else { return nil }
        return index
    }

    private func nextRecordingFrame() -> CGRect {
        CGRect(x: 10, y: sidebarLayer.bounds.height - 118, width: sidebarLayer.bounds.width - 20, height: runRowHeight - 4)
    }

    private func traceViewportFrame() -> CGRect {
        CGRect(x: 0,
               y: 0,
               width: sidebarLayer.bounds.width,
               height: max(sidebarLayer.bounds.height - 170, 1))
    }

    private func traceFrame(visualIndex: Int) -> CGRect {
        let contentHeight = max(traceContentLayer.bounds.height, traceViewportLayer.bounds.height)
        let y = contentHeight - CGFloat(visualIndex + 1) * runRowHeight
        return CGRect(x: 10, y: y, width: traceViewportLayer.bounds.width - 20, height: runRowHeight - 8)
    }

    private func selectTrace(at index: Int) {
        guard traces.indices.contains(index) else { return }
        blurProcessSearch()
        showingSetup = false
        selectedTraceID = traces[index].profileID
        lastProfile = nil
        selectedRange = nil
        resetFlameViewport()
        loadProfile(id: traces[index].profileID)
        updateColors()
    }

    private func handleMouseDragged(at point: CGPoint) {
        guard rangeDragStart != nil, lastProfile != nil, !showingSetup else { return }
        let timelinePoint = timelineLayer.convert(point, from: rootLayer)
        guard let time = timeForTimelinePoint(timelinePoint) else { return }
        setDraggingRange(end: time)
    }

    private func handleMouseUp(at point: CGPoint) {
        guard let dragStart = rangeDragStart, let profile = lastProfile, !showingSetup else { return }
        defer { rangeDragStart = nil }
        let timelinePoint = timelineLayer.convert(point, from: rootLayer)
        guard let time = timeForTimelinePoint(timelinePoint) else {
            selectedRange = 0...Double(profile.duration)
            updateTimeline()
            fetchSelectedRange()
            return
        }
        let lower = min(dragStart, time)
        let upper = max(dragStart, time)
        if upper - lower < 0.05 {
            selectedRange = 0...Double(profile.duration)
        } else {
            selectedRange = lower...upper
        }
        updateTimeline()
        fetchSelectedRange()
    }

    private func handleMouseMoved(at point: CGPoint) {
        guard !showingSetup, flameLayer.frame.contains(point) else {
            hideTooltip()
            return
        }
        let flamePoint = flameLayer.convert(point, from: rootLayer)
        guard let contentPoint = flameContentPoint(for: flamePoint),
              let hit = flameHitRegions.last(where: { $0.frame.contains(contentPoint) }) else {
            hideTooltip()
            return
        }
        showTooltip(for: hit, at: point)
    }

    private func handleKeyDown(keyCode: UInt16,
                               characters: String,
                               charactersIgnoringModifiers: String,
                               modifierFlags: NSEvent.ModifierFlags,
                               isARepeat: Bool) {
        _ = characters
        _ = charactersIgnoringModifiers
        _ = modifierFlags
        _ = isARepeat
        guard processSearchFocused else { return }
        if modifierFlags.contains(.command) {
            switch charactersIgnoringModifiers.lowercased() {
            case "a":
                selectAllProcessSearchText()
            case "c":
                writeProcessSearchSelectionToPasteboard(cut: false)
            case "x":
                writeProcessSearchSelectionToPasteboard(cut: true)
            case "v":
                readPasteboardIntoProcessSearch()
            default:
                break
            }
            return
        }
        if keyCode == 53 {
            if processSearchText.isEmpty {
                blurProcessSearch()
            } else {
                setProcessSearchText("")
            }
        }
    }

    private func handleTextInput(_ text: String,
                                 hasReplacementRange: Bool,
                                 replacementLocation: UInt64,
                                 replacementLength: UInt64) {
        guard processSearchFocused, !text.isEmpty else { return }
        let replacement: Range<Int>?
        if hasReplacementRange {
            let location = min(Int(replacementLocation), processSearchText.count)
            let length = min(Int(replacementLength), processSearchText.count - location)
            replacement = location..<(location + length)
        } else {
            replacement = nil
        }
        insertProcessSearchText(text, replacementRange: replacement)
    }

    private func handleTextCommand(_ command: String) {
        guard processSearchFocused else { return }
        switch command.trimmingCharacters(in: CharacterSet(charactersIn: ":")) {
        case "deleteBackward":
            deleteProcessSearchBackward()
        case "deleteForward":
            deleteProcessSearchForward()
        case "deleteWordBackward":
            deleteProcessSearchWordBackward()
        case "deleteWordForward":
            deleteProcessSearchWordForward()
        case "deleteToBeginningOfLine", "deleteToBeginningOfParagraph", "deleteToMark":
            replaceProcessSearchText(range: 0..<processSearchCursorPosition, with: "")
        case "deleteToEndOfLine", "deleteToEndOfParagraph":
            replaceProcessSearchText(range: processSearchCursorPosition..<processSearchText.count, with: "")
        case "moveLeft":
            moveProcessSearchCursor(to: processSearchCursorPosition - 1, modifySelection: false, collapsingSelectionTowardStart: true)
        case "moveRight":
            moveProcessSearchCursor(to: processSearchCursorPosition + 1, modifySelection: false, collapsingSelectionTowardStart: false)
        case "moveWordLeft":
            moveProcessSearchCursor(to: previousProcessSearchWordBoundary(from: processSearchCursorPosition), modifySelection: false, collapsingSelectionTowardStart: true)
        case "moveWordRight":
            moveProcessSearchCursor(to: nextProcessSearchWordBoundary(from: processSearchCursorPosition), modifySelection: false, collapsingSelectionTowardStart: false)
        case "moveToBeginningOfLine", "moveToBeginningOfDocument", "moveToBeginningOfParagraph", "moveToLeftEndOfLine":
            moveProcessSearchCursor(to: 0, modifySelection: false)
        case "moveToEndOfLine", "moveToEndOfDocument", "moveToEndOfParagraph", "moveToRightEndOfLine":
            moveProcessSearchCursor(to: processSearchText.count, modifySelection: false)
        case "moveLeftAndModifySelection":
            moveProcessSearchCursor(to: processSearchCursorPosition - 1, modifySelection: true)
        case "moveRightAndModifySelection":
            moveProcessSearchCursor(to: processSearchCursorPosition + 1, modifySelection: true)
        case "moveWordLeftAndModifySelection":
            moveProcessSearchCursor(to: previousProcessSearchWordBoundary(from: processSearchCursorPosition), modifySelection: true)
        case "moveWordRightAndModifySelection":
            moveProcessSearchCursor(to: nextProcessSearchWordBoundary(from: processSearchCursorPosition), modifySelection: true)
        case "moveToBeginningOfLineAndModifySelection", "moveToBeginningOfDocumentAndModifySelection", "moveToBeginningOfParagraphAndModifySelection", "moveToLeftEndOfLineAndModifySelection":
            moveProcessSearchCursor(to: 0, modifySelection: true)
        case "moveToEndOfLineAndModifySelection", "moveToEndOfDocumentAndModifySelection", "moveToEndOfParagraphAndModifySelection", "moveToRightEndOfLineAndModifySelection":
            moveProcessSearchCursor(to: processSearchText.count, modifySelection: true)
        case "selectAll":
            selectAllProcessSearchText()
        case "insertNewline", "cancelOperation":
            blurProcessSearch()
        default:
            break
        }
    }

    private func handleTextInputFocus(fieldID: UUID, hasFocus: Bool) {
        guard fieldID == Self.processSearchFieldID else { return }
        if hasFocus {
            focusProcessSearch(cursorPosition: processSearchCursorPosition, modifySelection: false)
        } else {
            blurProcessSearch()
        }
    }

    private func handleSetCursorPosition(fieldID: UUID, position: UInt64, modifySelection: Bool) {
        guard fieldID == Self.processSearchFieldID else { return }
        focusProcessSearch(cursorPosition: min(Int(position), processSearchText.count), modifySelection: modifySelection)
    }

    private func setDraggingRange(end: Double) {
        guard let dragStart = rangeDragStart else { return }
        let lower = min(dragStart, end)
        let upper = max(dragStart, end)
        selectedRange = lower...upper
        updateTimeline()
    }

    private func handleMagnification(_ magnification: CGFloat, at point: CGPoint) {
        guard !showingSetup, flameLayer.frame.contains(point), lastProfile != nil else { return }
        let flamePoint = flameLayer.convert(point, from: rootLayer)
        let viewport = flameGraphViewportRect()
        guard viewport.contains(flamePoint) else { return }

        let oldZoom = flameZoom
        let newZoom = min(max(oldZoom * (1 + magnification), 1), 16)
        guard abs(newZoom - oldZoom) > 0.001 else { return }

        let localX = flamePoint.x - viewport.minX
        let contentX = flameHorizontalScroll + localX
        flameZoom = newZoom
        updateFlameContentSizeForCurrentZoom(viewport: viewport)
        flameHorizontalScroll = (contentX * newZoom / oldZoom) - localX
        clampFlameScroll()
        hideTooltip()
        updateFlameTextOverlayFrames()
        updateFlameScrollPosition()
    }

    private func flameContentPoint(for flamePoint: CGPoint) -> CGPoint? {
        let viewport = flameGraphViewportRect()
        guard viewport.contains(flamePoint), flameContentSize.width > 0, flameContentSize.height > 0 else { return nil }
        let local = CGPoint(x: flamePoint.x - viewport.minX, y: flamePoint.y - viewport.minY)
        let contentOriginY = viewport.height - flameContentSize.height + flameVerticalScroll
        let scale = flameLiveZoomScale(viewport: viewport)
        return CGPoint(x: (local.x + flameHorizontalScroll) / max(scale, 0.0001),
                       y: local.y - contentOriginY)
    }

    private func showTooltip(for hit: FlameHitRegion, at point: CGPoint) {
        guard hit.total > 0 else {
            hideTooltip()
            return
        }
        let percent = Double(hit.count) * 100.0 / Double(hit.total)
        let binary = hit.binary.isEmpty ? "Unknown binary" : hit.binary
        let text = "\(hit.symbol)\nBinary: \(binary)\nSamples: \(hit.count) of \(hit.total) (\(String(format: "%.1f", percent))%)\nStack depth: \(hit.depth + 1)"
        tooltipTextLayer.string = text

        let maxWidth = min(max(rootLayer.bounds.width * 0.5, 260), 560)
        let longest = text.components(separatedBy: "\n").map { CGFloat($0.count) }.max() ?? 1
        let width = min(max(longest * 6.4 + 22, 220), maxWidth)
        let height = CGFloat(text.components(separatedBy: "\n").count) * 17 + 18
        var frame = CGRect(x: point.x + 14, y: point.y + 16, width: width, height: height)
        if frame.maxX > rootLayer.bounds.maxX - 8 {
            frame.origin.x = point.x - width - 14
        }
        if frame.maxY > rootLayer.bounds.maxY - 8 {
            frame.origin.y = point.y - height - 14
        }
        frame.origin.x = min(max(frame.origin.x, 8), max(rootLayer.bounds.maxX - width - 8, 8))
        frame.origin.y = min(max(frame.origin.y, 8), max(rootLayer.bounds.maxY - height - 8, 8))

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tooltipLayer.frame = frame
        tooltipTextLayer.frame = tooltipLayer.bounds.insetBy(dx: 11, dy: 8)
        tooltipLayer.isHidden = false
        CATransaction.commit()
    }

    private func hideTooltip() {
        guard !tooltipLayer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tooltipLayer.isHidden = true
        CATransaction.commit()
    }

    private func fetchProfiles(selectLatestIfNeeded: Bool) {
        guard let endpoint = profileListEndpoint, let urlSession else { return }
        urlSession.dataTask(with: endpoint) { [weak self] data, _, error in
            let result = data.flatMap(ProfileBinary.decodeProfileList)
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.traces = result.profiles
                    self.isRecording = result.recording
                    self.activeRecordingID = result.recording ? result.recordingID : nil
                    if result.recording, self.selectedTraceID == nil {
                        self.showingSetup = false
                        self.selectedTraceID = result.recordingID
                        self.lastProfile = nil
                        self.selectedRange = nil
                        self.statusLayer.string = "Recording..."
                    } else if selectLatestIfNeeded, self.selectedTraceID == nil, let latest = result.profiles.last {
                        self.showingSetup = false
                        self.selectedTraceID = latest.profileID
                        self.resetFlameViewport()
                        self.loadProfile(id: latest.profileID)
                    } else if let selectedTraceID = self.selectedTraceID,
                              !self.traces.contains(where: { $0.profileID == selectedTraceID }) &&
                              selectedTraceID != self.activeRecordingID {
                        self.selectedTraceID = nil
                        self.showingSetup = true
                    }
                    self.updateColors()
                } else {
                    self.statusLayer.string = error?.localizedDescription ?? "Could not load recordings."
                }
            }
        }.resume()
    }

    private func fetchProcesses() {
        guard let endpoint = processesEndpoint, let urlSession else { return }
        statusLayer.string = "Loading processes..."
        urlSession.dataTask(with: endpoint) { [weak self] data, _, error in
            let result = data.flatMap(ProfileBinary.decodeProcesses)
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.processes = result.processes
                    if let selectedPID = self.selectedPID,
                       !self.processes.contains(where: { $0.pid == selectedPID }) {
                        self.selectedPID = nil
                    }
                    self.clampProcessScroll()
                    self.statusLayer.string = self.selectedPID == nil ? "Choose a process for the next recording." : self.statusLayer.string
                    self.updateColors()
                } else {
                    self.statusLayer.string = error?.localizedDescription ?? "Could not load processes."
                }
            }
        }.resume()
    }

    private func startRecording() {
        guard !isRecording, let selectedPID, let profileStartEndpoint, let urlSession else { return }
        var components = URLComponents(url: profileStartEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "pid", value: String(selectedPID)),
            URLQueryItem(name: "frequency", value: "999")
        ]
        guard let url = components?.url else { return }
        isBusy = true
        statusLayer.string = "Starting recording for pid \(selectedPID)..."
        updateColors()
        urlSession.dataTask(with: url) { [weak self] data, response, error in
            let decoded = data.flatMap(ProfileBinary.decodeRecording)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                if let decoded {
                    self.isRecording = decoded.recording
                    self.activeRecordingID = decoded.recordingID
                    self.activeRecordingPID = decoded.pid
                    self.activeRecordingFrequency = decoded.frequency
                    self.recordingStartedAt = Date()
                    self.traceScroll = 0
                    self.showingSetup = false
                    self.selectedTraceID = decoded.recordingID
                    self.lastProfile = nil
                    self.selectedRange = nil
                    self.resetFlameViewport()
                    self.blurProcessSearch()
                    self.statusLayer.string = "Recording pid \(decoded.pid) at \(decoded.frequency) Hz..."
                } else {
                    self.statusLayer.string = error?.localizedDescription ?? "Recording failed (\(status)): \(body)"
                }
                self.updateColors()
            }
        }.resume()
    }

    private func stopRecording() {
        guard isRecording, let profileStopEndpoint, let urlSession else { return }
        isBusy = true
        statusLayer.string = "Stopping recording and building profile..."
        updateColors()
        urlSession.dataTask(with: profileStopEndpoint) { [weak self] data, response, error in
            let decoded = data.flatMap(ProfileBinary.decodeProfile)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.isRecording = false
                self.activeRecordingID = nil
                self.activeRecordingPID = nil
                self.activeRecordingFrequency = nil
                self.recordingStartedAt = nil
                if let decoded {
                    self.lastProfile = decoded
                    self.selectedTraceID = decoded.profileID
                    self.showingSetup = false
                    self.selectedRange = decoded.rangeStart...decoded.rangeEnd
                    self.resetFlameViewport()
                    self.statusLayer.string = self.summaryText(for: decoded)
                    self.fetchProfiles(selectLatestIfNeeded: false)
                } else {
                    self.statusLayer.string = error?.localizedDescription ?? "Stop failed (\(status)): \(body)"
                }
                self.updateColors()
            }
        }.resume()
    }

    private func loadProfile(id: UInt64) {
        guard let profileRangeEndpoint, let urlSession else { return }
        var components = URLComponents(url: profileRangeEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "profileID", value: String(id))]
        guard let url = components?.url else { return }
        isFetchingRange = true
        statusLayer.string = "Loading recording..."
        urlSession.dataTask(with: url) { [weak self] data, response, error in
            let decoded = data.flatMap(ProfileBinary.decodeProfile)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Task { @MainActor in
                guard let self else { return }
                self.isFetchingRange = false
                if let decoded {
                    self.lastProfile = decoded
                    self.selectedRange = decoded.rangeStart...decoded.rangeEnd
                    self.resetFlameViewport()
                    self.statusLayer.string = self.summaryText(for: decoded)
                } else {
                    self.statusLayer.string = error?.localizedDescription ?? "Load failed (\(status)): \(body)"
                }
                self.updateColors()
            }
        }.resume()
    }

    private func deleteTrace(id: UInt64) {
        guard let profileDeleteEndpoint, let urlSession else { return }
        var components = URLComponents(url: profileDeleteEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "profileID", value: String(id))]
        guard let url = components?.url else { return }

        let deletedSelectedTrace = selectedTraceID == id
        statusLayer.string = "Deleting recording..."
        urlSession.dataTask(with: url) { [weak self] data, response, error in
            let result = data.flatMap(ProfileBinary.decodeProfileList)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.traces = result.profiles
                    self.isRecording = result.recording
                    self.activeRecordingID = result.recording ? result.recordingID : nil
                    if deletedSelectedTrace {
                        if let replacement = result.profiles.last {
                            self.showingSetup = false
                            self.selectedTraceID = replacement.profileID
                            self.lastProfile = nil
                            self.selectedRange = nil
                            self.resetFlameViewport()
                            self.loadProfile(id: replacement.profileID)
                        } else {
                            self.showingSetup = true
                            self.selectedTraceID = nil
                            self.lastProfile = nil
                            self.selectedRange = nil
                            self.statusLayer.string = "Choose a process for the next recording."
                        }
                    } else if let selectedTraceID = self.selectedTraceID,
                              !result.profiles.contains(where: { $0.profileID == selectedTraceID }) {
                        self.showingSetup = true
                        self.selectedTraceID = nil
                        self.lastProfile = nil
                        self.selectedRange = nil
                    } else {
                        self.statusLayer.string = "Deleted recording."
                    }
                    self.updateColors()
                } else {
                    self.statusLayer.string = error?.localizedDescription ?? "Delete failed (\(status)): \(body)"
                }
            }
        }.resume()
    }

    private func fetchSelectedRange() {
        guard let profile = lastProfile,
              let selectedRange,
              let profileRangeEndpoint,
              let urlSession else { return }
        var components = URLComponents(url: profileRangeEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "profileID", value: String(profile.profileID)),
            URLQueryItem(name: "start", value: String(format: "%.6f", selectedRange.lowerBound)),
            URLQueryItem(name: "end", value: String(format: "%.6f", selectedRange.upperBound))
        ]
        guard let url = components?.url else { return }
        isFetchingRange = true
        statusLayer.string = "Filtering \(formatDuration(selectedRange.upperBound - selectedRange.lowerBound))..."
        urlSession.dataTask(with: url) { [weak self] data, response, error in
            let decoded = data.flatMap(ProfileBinary.decodeProfile)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Task { @MainActor in
                guard let self else { return }
                self.isFetchingRange = false
                if let decoded {
                    self.lastProfile = decoded
                    self.selectedRange = decoded.rangeStart...decoded.rangeEnd
                    self.statusLayer.string = self.summaryText(for: decoded)
                } else {
                    self.statusLayer.string = error?.localizedDescription ?? "Range failed (\(status)): \(body)"
                }
                self.updateTimeline()
                self.updateFlameGraph()
            }
        }.resume()
    }

    private func summaryText(for profile: ProfileResponse) -> String {
        let duration = max(profile.rangeEnd - profile.rangeStart, 0)
        let cpu = profile.cpuMilliseconds >= 0 ? ", \(String(format: "%.1f", profile.cpuMilliseconds)) ms CPU total" : ""
        if profile.sampleCount > 0 {
            return "Captured \(profile.sampleCount) samples across \(profile.aggregateCount) stacks in \(formatDuration(duration))\(cpu)."
        }
        let detail = profile.status?.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail?.isEmpty == false ? detail! : "No stack samples in selected range."
    }

    private func updateSidebar() {
        guard sidebarLayer.superlayer != nil else { return }
        appearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            sidebarLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

            let title = makeTextLayer(size: 12, weight: .semibold)
            title.string = "PROFILE"
            title.foregroundColor = NSColor.secondaryLabelColor.cgColor
            title.frame = CGRect(x: 16, y: sidebarLayer.bounds.height - 32, width: max(sidebarLayer.bounds.width - 72, 1), height: 16)
            sidebarLayer.addSublayer(title)
            sidebarLayer.addSublayer(recordToggleButtonLayer)

            sidebarLayer.addSublayer(makeSidebarRow(frame: nextRecordingFrame(),
                                                    title: "Next Recording",
                                                    subtitle: selectedProcessSubtitle,
                                                    iconName: "record.circle",
                                                    selected: showingSetup))

            let runs = makeTextLayer(size: 12, weight: .semibold)
            runs.string = "TRACES"
            runs.foregroundColor = NSColor.secondaryLabelColor.cgColor
            runs.frame = CGRect(x: 16, y: sidebarLayer.bounds.height - 152, width: sidebarLayer.bounds.width - 32, height: 16)
            sidebarLayer.addSublayer(runs)

            traceViewportLayer.frame = traceViewportFrame()
            traceScrollbarLayer.frame = sidebarLayer.bounds
            sidebarLayer.addSublayer(traceViewportLayer)
            sidebarLayer.addSublayer(traceScrollbarLayer)
            traceContentLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

            let viewport = traceViewportLayer.bounds
            let contentHeight = max(CGFloat(traceRowCount()) * runRowHeight, viewport.height)
            traceContentLayer.bounds = CGRect(x: 0, y: 0, width: viewport.width, height: contentHeight)
            clampTraceScroll()

            let extraTraceRows = activeRecordingTraceRowCount()
            if extraTraceRows > 0, let activeRecordingID {
                let subtitle = activeRecordingPID.map { "pid \($0)  Recording" } ?? "Recording"
                traceContentLayer.addSublayer(makeSidebarRow(frame: traceFrame(visualIndex: 0),
                                                             title: "Recording",
                                                             subtitle: subtitle,
                                                             iconName: "chart.bar.fill",
                                                             selected: selectedTraceID == activeRecordingID))
            }

            for index in traces.indices.reversed() {
                let visualIndex = traces.count - 1 - index + extraTraceRows
                let frame = traceFrame(visualIndex: visualIndex)
                let trace = traces[index]
                let title = "Run \(index + 1)"
                let subtitle = "pid \(trace.pid)  \(formatDuration(trace.duration))"
                traceContentLayer.addSublayer(makeSidebarRow(frame: frame,
                                                             title: title,
                                                             subtitle: subtitle,
                                                             iconName: "chart.bar.fill",
                                                             selected: selectedTraceID == trace.profileID))
            }

            positionTraceContentLayer()
            addTraceScrollbar()
            CATransaction.commit()
        }
    }

    private var selectedProcessSubtitle: String {
        guard let selectedPID else { return "Choose a target" }
        if let process = processes.first(where: { $0.pid == selectedPID }) {
            return "\(process.name) (\(selectedPID))"
        }
        return "pid \(selectedPID)"
    }

    private func makeSidebarRow(frame: CGRect, title: String, subtitle: String, iconName: String?, selected: Bool) -> CALayer {
        let row = CALayer()
        row.frame = frame
        row.cornerRadius = 8
        if selected {
            row.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
        }

        let textX: CGFloat
        if let iconName {
            let icon = makeSymbolLayer(iconName, color: selected ? .white : NSColor.secondaryLabelColor)
            icon.frame = CGRect(x: 12, y: frame.height - 23, width: 16, height: 16)
            row.addSublayer(icon)
            textX = 38
        } else {
            textX = 16
        }

        let titleLayer = makeTextLayer(size: 13, weight: .semibold)
        titleLayer.string = title
        titleLayer.foregroundColor = selected ? NSColor.white.cgColor : NSColor.labelColor.cgColor
        titleLayer.frame = CGRect(x: textX, y: frame.height - 23, width: max(frame.width - textX - 12, 1), height: 16)
        row.addSublayer(titleLayer)

        let subtitleLayer = makeTextLayer(size: 12, weight: .regular)
        subtitleLayer.string = subtitle
        subtitleLayer.foregroundColor = selected ? NSColor.white.withAlphaComponent(0.82).cgColor : NSColor.secondaryLabelColor.cgColor
        subtitleLayer.frame = CGRect(x: textX, y: 7, width: max(frame.width - textX - 12, 1), height: 15)
        row.addSublayer(subtitleLayer)
        return row
    }

    private func activeRecordingTraceRowCount() -> Int {
        guard isRecording,
              let activeRecordingID,
              !traces.contains(where: { $0.profileID == activeRecordingID }) else {
            return 0
        }
        return 1
    }

    private func traceRowCount() -> Int {
        traces.count + activeRecordingTraceRowCount()
    }

    private func positionTraceContentLayer() {
        let viewport = traceViewportLayer.bounds
        let contentHeight = max(traceContentLayer.bounds.height, viewport.height)
        traceContentLayer.frame = CGRect(x: 0,
                                         y: viewport.height - contentHeight + traceScroll,
                                         width: viewport.width,
                                         height: contentHeight)
    }

    private func updateTraceScrollPosition() {
        guard traceViewportLayer.superlayer != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        positionTraceContentLayer()
        addTraceScrollbar()
        CATransaction.commit()
    }

    private func addTraceScrollbar() {
        traceScrollbarLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let viewportFrame = traceViewportLayer.frame
        let contentHeight = CGFloat(traceRowCount()) * runRowHeight
        guard contentHeight > viewportFrame.height + 1 else { return }

        let thickness: CGFloat = 9
        let inset: CGFloat = 5
        let trackFrame = CGRect(x: max(viewportFrame.maxX - inset - thickness, viewportFrame.minX + inset),
                                y: viewportFrame.minY + inset,
                                width: thickness,
                                height: max(viewportFrame.height - inset * 2, 1))
        let track = CALayer()
        track.frame = trackFrame
        track.cornerRadius = thickness * 0.5
        track.backgroundColor = resolvedCGColor(scrollbarTrackColor)
        traceScrollbarLayer.addSublayer(track)

        let proportion = min(max(viewportFrame.height / max(contentHeight, 1), 0), 1)
        let thumbHeight = min(max(trackFrame.height * proportion, 24), trackFrame.height)
        let range = max(trackFrame.height - thumbHeight, 0)
        let progress = traceScroll / max(contentHeight - viewportFrame.height, 1)
        let thumb = CALayer()
        thumb.frame = CGRect(x: trackFrame.minX,
                             y: trackFrame.maxY - thumbHeight - range * progress,
                             width: thickness,
                             height: thumbHeight)
        thumb.cornerRadius = thickness * 0.5
        thumb.backgroundColor = resolvedCGColor(scrollbarThumbColor)
        traceScrollbarLayer.addSublayer(thumb)
    }

    private func updateProcessRows() {
        guard processListLayer.superlayer != nil else { return }
        appearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            processListLayer.isHidden = !showingSetup
            processChromeLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            processScrollbarLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

            guard showingSetup else {
                processViewportLayer.isHidden = true
                processSearchLayer.removeFromSuperlayer()
                CATransaction.commit()
                updateTextInputState()
                return
            }

            processViewportLayer.isHidden = false

            let header = makeTextLayer(size: 18, weight: .semibold)
            header.string = "Next Recording"
            header.frame = CGRect(x: 24, y: processListLayer.bounds.height - 42, width: max(processListLayer.bounds.width - 48, 1), height: 24)
            processChromeLayer.addSublayer(header)

            let subhead = makeTextLayer(size: 13, weight: .regular)
            subhead.string = "Choose a process, then press Record."
            subhead.foregroundColor = NSColor.secondaryLabelColor.cgColor
            subhead.frame = CGRect(x: 24, y: processListLayer.bounds.height - 66, width: max(processListLayer.bounds.width - 48, 1), height: 18)
            processChromeLayer.addSublayer(subhead)

            processSearchLayer.frame = processSearchFrame()
            processSearchLayer.cornerRadius = 7
            processChromeLayer.addSublayer(processSearchLayer)

            let listFrame = processTableFrame()
            let listBackground = CALayer()
            listBackground.frame = listFrame
            listBackground.cornerRadius = 8
            listBackground.borderWidth = 1
            listBackground.borderColor = NSColor.separatorColor.cgColor
            listBackground.backgroundColor = tableBackgroundColor.cgColor
            processChromeLayer.addSublayer(listBackground)

            processViewportLayer.frame = listFrame.insetBy(dx: 1, dy: 1)
            rebuildProcessContent()
            updateProcessSearchDisplay()
            updateProcessScrollPosition()
            CATransaction.commit()
        }
        updateTextInputState()
    }

    private func processSearchFrame() -> CGRect {
        CGRect(x: 24,
               y: processListLayer.bounds.height - 116,
               width: max(processListLayer.bounds.width - 48, 1),
               height: 34)
    }

    private func processTableFrame() -> CGRect {
        CGRect(x: 18,
               y: 18,
               width: max(processListLayer.bounds.width - 36, 1),
               height: max(processListLayer.bounds.height - 148, 1))
    }

    private func filteredProcessIndexList() -> [Int] {
        let query = processSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return Array(processes.indices) }
        return processes.indices.filter { index in
            let process = processes[index]
            return process.name.lowercased().contains(query) ||
                process.command.lowercased().contains(query) ||
                String(process.pid).contains(query)
        }
    }

    private func rebuildProcessContent() {
        filteredProcessIndices = filteredProcessIndexList()
        clampProcessScroll()
        processContentLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let viewport = processViewportLayer.bounds
        let contentHeight = max(CGFloat(filteredProcessIndices.count) * rowHeight, viewport.height)
        processContentLayer.bounds = CGRect(x: 0, y: 0, width: viewport.width, height: contentHeight)

        if filteredProcessIndices.isEmpty {
            let empty = makeTextLayer(size: 13, weight: .regular)
            empty.string = processSearchText.isEmpty ? "No processes." : "No matching processes."
            empty.foregroundColor = resolvedCGColor(NSColor.secondaryLabelColor)
            empty.frame = CGRect(x: 14, y: max(contentHeight - 38, 8), width: max(viewport.width - 28, 1), height: 18)
            processContentLayer.addSublayer(empty)
            return
        }

        for displayIndex in filteredProcessIndices.indices {
            let process = processes[filteredProcessIndices[displayIndex]]
            let y = contentHeight - CGFloat(displayIndex + 1) * rowHeight
            let row = CALayer()
            row.frame = CGRect(x: 0, y: y, width: viewport.width, height: rowHeight)
            if process.pid == selectedPID {
                row.backgroundColor = resolvedCGColor(NSColor.selectedContentBackgroundColor.withAlphaComponent(0.28))
            } else if displayIndex % 2 == 1 {
                row.backgroundColor = resolvedCGColor(NSColor.labelColor.withAlphaComponent(0.035))
            }

            let pidLayer = makeTextLayer(size: 12, weight: .regular, alignment: .right)
            pidLayer.string = "\(process.pid)"
            pidLayer.foregroundColor = resolvedCGColor(NSColor.secondaryLabelColor)
            pidLayer.frame = CGRect(x: 12, y: 7, width: 58, height: 16)
            row.addSublayer(pidLayer)

            let nameLayer = makeTextLayer(size: 13, weight: .medium)
            nameLayer.string = process.name
            nameLayer.foregroundColor = resolvedCGColor(NSColor.labelColor)
            nameLayer.frame = CGRect(x: 84, y: 7, width: max(row.bounds.width - 98, 1), height: 16)
            row.addSublayer(nameLayer)

            processContentLayer.addSublayer(row)
        }
    }

    private func updateProcessScrollPosition() {
        guard processViewportLayer.superlayer != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let viewport = processViewportLayer.bounds
        let contentHeight = max(processContentLayer.bounds.height, viewport.height)
        processContentLayer.frame = CGRect(x: 0,
                                           y: viewport.height - contentHeight + processScroll,
                                           width: viewport.width,
                                           height: contentHeight)
        addProcessScrollbar()
        CATransaction.commit()
    }

    private func addProcessScrollbar() {
        processScrollbarLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard showingSetup else { return }
        let viewportFrame = processViewportLayer.frame
        let contentHeight = CGFloat(filteredProcessIndices.count) * rowHeight
        guard contentHeight > viewportFrame.height + 1 else { return }

        let thickness: CGFloat = 9
        let inset: CGFloat = 5
        let trackFrame = CGRect(x: min(viewportFrame.maxX + inset, processListLayer.bounds.maxX - inset - thickness),
                                y: viewportFrame.minY,
                                width: thickness,
                                height: viewportFrame.height)
        let track = CALayer()
        track.frame = trackFrame
        track.cornerRadius = thickness * 0.5
        track.backgroundColor = resolvedCGColor(scrollbarTrackColor)
        processScrollbarLayer.addSublayer(track)

        let proportion = min(max(viewportFrame.height / max(contentHeight, 1), 0), 1)
        let thumbHeight = min(max(trackFrame.height * proportion, 24), trackFrame.height)
        let range = max(trackFrame.height - thumbHeight, 0)
        let progress = processScroll / max(contentHeight - viewportFrame.height, 1)
        let thumb = CALayer()
        thumb.frame = CGRect(x: trackFrame.minX,
                             y: trackFrame.maxY - thumbHeight - range * progress,
                             width: thickness,
                             height: thumbHeight)
        thumb.cornerRadius = thickness * 0.5
        thumb.backgroundColor = resolvedCGColor(scrollbarThumbColor)
        processScrollbarLayer.addSublayer(thumb)
    }

    private func updateProcessSearchDisplay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let bounds = processSearchLayer.bounds
        processSearchIconLayer.frame = CGRect(x: 10, y: 8, width: 16, height: 16)
        let textFrame = processSearchTextFrame()
        processSearchPlaceholderLayer.frame = textFrame
        processSearchTextLayer.frame = textFrame
        processSearchTextLayer.string = processSearchText
        processSearchTextLayer.isHidden = processSearchText.isEmpty
        processSearchPlaceholderLayer.isHidden = !processSearchText.isEmpty
        updateProcessSearchSelectionLayer()
        let corner = min(bounds.height * 0.5, 7)
        processSearchLayer.cornerRadius = corner

        guard processSearchFocused, processSearchSelectionRange() == nil else {
            processSearchCursorLayer.isHidden = true
            processSearchCursorLayer.removeAnimation(forKey: processSearchCaretBlinkAnimationKey)
            return
        }

        let caretRect = processSearchCaretRect()
        processSearchCursorLayer.frame = caretRect
        processSearchCursorLayer.isHidden = false
        processSearchCursorLayer.opacity = 1
        processSearchCursorLayer.removeAnimation(forKey: processSearchCaretBlinkAnimationKey)
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = 0.55
        animation.beginTime = CACurrentMediaTime() + 0.55
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        processSearchCursorLayer.add(animation, forKey: processSearchCaretBlinkAnimationKey)
    }

    private func updateProcessSearchSelectionLayer() {
        guard processSearchFocused,
              let range = processSearchSelectionRange(),
              range.lowerBound < range.upperBound else {
            processSearchSelectionLayer.isHidden = true
            return
        }

        let textFrame = processSearchTextFrame()
        let line = makeProcessSearchLine()
        let lower = offsetForProcessSearchCharacter(line: line, index: range.lowerBound, maxWidth: textFrame.width)
        let upper = offsetForProcessSearchCharacter(line: line, index: range.upperBound, maxWidth: textFrame.width)
        processSearchSelectionLayer.frame = CGRect(x: textFrame.minX + min(lower, upper),
                                                   y: textFrame.minY - 1,
                                                   width: max(abs(upper - lower), 1),
                                                   height: textFrame.height + 2)
        processSearchSelectionLayer.cornerRadius = 2
        processSearchSelectionLayer.isHidden = false
    }

    private func processSearchTextFrame() -> CGRect {
        CGRect(x: 32,
               y: 8,
               width: max(processSearchLayer.bounds.width - 42, 1),
               height: 17)
    }

    private func processSearchCaretRect() -> CGRect {
        let textFrame = processSearchTextFrame()
        let contentsScale = max(processSearchTextLayer.contentsScale, 1)
        let caretWidth = max(CGFloat(1), 1 / contentsScale)
        let offset: CGFloat
        if processSearchText.isEmpty {
            offset = 0
        } else {
            let line = makeProcessSearchLine()
            offset = offsetForProcessSearchCharacter(line: line,
                                                     index: processSearchCursorPosition,
                                                     maxWidth: textFrame.width)
        }
        return CGRect(x: min(max(textFrame.minX + offset, textFrame.minX), textFrame.maxX - caretWidth),
                      y: textFrame.minY,
                      width: caretWidth,
                      height: textFrame.height)
    }

    private func makeProcessSearchLine() -> CTLine {
        let attributed = NSAttributedString(string: processSearchText,
                                            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .regular)])
        return CTLineCreateWithAttributedString(attributed)
    }

    private func offsetForProcessSearchCharacter(line: CTLine, index: Int, maxWidth: CGFloat) -> CGFloat {
        let utf16Index = utf16Offset(forCharacterIndex: index, in: processSearchText)
        var secondaryOffset: CGFloat = 0
        let primary = CTLineGetOffsetForStringIndex(line, utf16Index, &secondaryOffset)
        let offset = max(primary, secondaryOffset)
        return offset.isFinite ? min(max(offset, 0), maxWidth) : 0
    }

    private func processSearchCursorPosition(at point: CGPoint) -> Int {
        let textFrame = processSearchLayer.convert(processSearchTextFrame(), to: processListLayer)
        let localX = max(0, min(point.x - textFrame.minX, textFrame.width))
        guard !processSearchText.isEmpty else { return 0 }
        let line = makeProcessSearchLine()
        let utf16Index = CTLineGetStringIndexForPosition(line, CGPoint(x: localX, y: 0))
        guard utf16Index != kCFNotFound else { return processSearchText.count }
        return characterIndex(forUTF16: utf16Index, in: processSearchText)
    }

    private func focusProcessSearch(cursorPosition: Int, modifySelection: Bool) {
        processSearchFocused = true
        moveProcessSearchCursor(to: cursorPosition, modifySelection: modifySelection)
        updateProcessSearchDisplay()
        updateColors()
        updateTextInputState()
    }

    private func blurProcessSearch() {
        guard processSearchFocused else { return }
        processSearchFocused = false
        processSearchSelectionAnchor = nil
        updateProcessSearchDisplay()
        updateColors()
        updateTextInputState()
    }

    private func setProcessSearchText(_ text: String) {
        processSearchText = text
        processSearchCursorPosition = min(processSearchCursorPosition, processSearchText.count)
        processSearchSelectionAnchor = nil
        processScroll = 0
        rebuildProcessContent()
        updateProcessSearchDisplay()
        updateProcessScrollPosition()
        updateTextInputState()
    }

    private func insertProcessSearchText(_ text: String, replacementRange: Range<Int>?) {
        let range = replacementRange ?? processSearchSelectionRange() ?? processSearchCursorPosition..<processSearchCursorPosition
        replaceProcessSearchText(range: range, with: text)
    }

    private func replaceProcessSearchText(range: Range<Int>, with replacement: String) {
        let lower = min(max(range.lowerBound, 0), processSearchText.count)
        let upper = min(max(range.upperBound, lower), processSearchText.count)
        let start = processSearchText.index(processSearchText.startIndex, offsetBy: lower)
        let end = processSearchText.index(processSearchText.startIndex, offsetBy: upper)
        processSearchText.replaceSubrange(start..<end, with: replacement)
        processSearchCursorPosition = lower + replacement.count
        processSearchSelectionAnchor = nil
        setProcessSearchText(processSearchText)
    }

    private func deleteProcessSearchBackward() {
        if deleteProcessSearchSelection() {
            return
        }
        guard processSearchCursorPosition > 0 else { return }
        replaceProcessSearchText(range: (processSearchCursorPosition - 1)..<processSearchCursorPosition, with: "")
    }

    private func deleteProcessSearchForward() {
        if deleteProcessSearchSelection() {
            return
        }
        guard processSearchCursorPosition < processSearchText.count else { return }
        replaceProcessSearchText(range: processSearchCursorPosition..<(processSearchCursorPosition + 1), with: "")
    }

    @discardableResult
    private func deleteProcessSearchSelection() -> Bool {
        guard let range = processSearchSelectionRange() else { return false }
        replaceProcessSearchText(range: range, with: "")
        return true
    }

    private func deleteProcessSearchWordBackward() {
        if deleteProcessSearchSelection() {
            return
        }
        let boundary = previousProcessSearchWordBoundary(from: processSearchCursorPosition)
        replaceProcessSearchText(range: boundary..<processSearchCursorPosition, with: "")
    }

    private func deleteProcessSearchWordForward() {
        if deleteProcessSearchSelection() {
            return
        }
        let boundary = nextProcessSearchWordBoundary(from: processSearchCursorPosition)
        replaceProcessSearchText(range: processSearchCursorPosition..<boundary, with: "")
    }

    private func moveProcessSearchCursor(to position: Int,
                                         modifySelection: Bool,
                                         collapsingSelectionTowardStart: Bool? = nil) {
        let clamped = min(max(position, 0), processSearchText.count)
        if modifySelection {
            if processSearchSelectionAnchor == nil {
                processSearchSelectionAnchor = processSearchCursorPosition
            }
            processSearchCursorPosition = clamped
        } else if let range = processSearchSelectionRange(), let collapseToStart = collapsingSelectionTowardStart {
            processSearchCursorPosition = collapseToStart ? range.lowerBound : range.upperBound
            processSearchSelectionAnchor = nil
        } else {
            processSearchCursorPosition = clamped
            processSearchSelectionAnchor = nil
        }
        updateProcessSearchDisplay()
        updateTextInputState()
    }

    private func selectAllProcessSearchText() {
        guard processSearchFocused else { return }
        processSearchSelectionAnchor = 0
        processSearchCursorPosition = processSearchText.count
        updateProcessSearchDisplay()
        updateTextInputState()
    }

    private func processSearchSelectionRange() -> Range<Int>? {
        guard let anchor = processSearchSelectionAnchor, anchor != processSearchCursorPosition else { return nil }
        let lower = min(anchor, processSearchCursorPosition)
        let upper = max(anchor, processSearchCursorPosition)
        return lower..<upper
    }

    private func selectedProcessSearchText() -> String? {
        guard let range = processSearchSelectionRange() else { return nil }
        let start = processSearchText.index(processSearchText.startIndex, offsetBy: range.lowerBound)
        let end = processSearchText.index(processSearchText.startIndex, offsetBy: range.upperBound)
        return String(processSearchText[start..<end])
    }

    private func previousProcessSearchWordBoundary(from position: Int) -> Int {
        guard !processSearchText.isEmpty else { return 0 }
        let clamped = min(max(position, 0), processSearchText.count)
        guard clamped > 0 else { return 0 }

        let tokenizer = CFStringTokenizerCreate(kCFAllocatorDefault,
                                                processSearchText as CFString,
                                                CFRangeMake(0, processSearchText.utf16.count),
                                                kCFStringTokenizerUnitWordBoundary,
                                                nil)
        var previous = 0
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType.rawValue != 0 {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let end = characterIndex(forUTF16: range.location + range.length, in: processSearchText)
            if end >= clamped {
                break
            }
            previous = end
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return previous
    }

    private func nextProcessSearchWordBoundary(from position: Int) -> Int {
        guard !processSearchText.isEmpty else { return 0 }
        let clamped = min(max(position, 0), processSearchText.count)
        guard clamped < processSearchText.count else { return processSearchText.count }

        let tokenizer = CFStringTokenizerCreate(kCFAllocatorDefault,
                                                processSearchText as CFString,
                                                CFRangeMake(0, processSearchText.utf16.count),
                                                kCFStringTokenizerUnitWordBoundary,
                                                nil)
        var tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        while tokenType.rawValue != 0 {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let end = characterIndex(forUTF16: range.location + range.length, in: processSearchText)
            if end > clamped {
                return end
            }
            tokenType = CFStringTokenizerAdvanceToNextToken(tokenizer)
        }
        return processSearchText.count
    }

    private func showProcessSearchContextMenu(at point: CGPoint) {
        let menuID = UUID()
        processSearchContextMenuIDs.insert(menuID)
        let hasSelection = processSearchSelectionRange() != nil
        let items = [
            OuterframeContextMenuItem(id: "cut",
                                      title: "Cut",
                                      isEnabled: hasSelection,
                                      keyEquivalent: "x",
                                      keyEquivalentModifierMask: UInt32(truncatingIfNeeded: NSEvent.ModifierFlags.command.rawValue)),
            OuterframeContextMenuItem(id: "copy",
                                      title: "Copy",
                                      isEnabled: hasSelection,
                                      keyEquivalent: "c",
                                      keyEquivalentModifierMask: UInt32(truncatingIfNeeded: NSEvent.ModifierFlags.command.rawValue)),
            OuterframeContextMenuItem(id: "paste",
                                      title: "Paste",
                                      keyEquivalent: "v",
                                      keyEquivalentModifierMask: UInt32(truncatingIfNeeded: NSEvent.ModifierFlags.command.rawValue)),
            OuterframeContextMenuItem(id: "separator", title: "", kind: .separator),
            OuterframeContextMenuItem(id: "selectAll",
                                      title: "Select All",
                                      isEnabled: !processSearchText.isEmpty,
                                      keyEquivalent: "a",
                                      keyEquivalentModifierMask: UInt32(truncatingIfNeeded: NSEvent.ModifierFlags.command.rawValue))
        ]
        outerframeHost.showContextMenu(menuID: menuID, items: items, at: point)
    }

    private func handleProcessSearchContextMenuSelection(itemID: String) {
        switch itemID {
        case "cut":
            writeProcessSearchSelectionToPasteboard(cut: true)
        case "copy":
            writeProcessSearchSelectionToPasteboard(cut: false)
        case "paste":
            readPasteboardIntoProcessSearch()
        case "selectAll":
            selectAllProcessSearchText()
        default:
            break
        }
    }

    private func processSearchPasteboardItems() -> [OuterContentPasteboardItem] {
        guard let text = selectedProcessSearchText(),
              let data = text.data(using: .utf8) else { return [] }
        return [OuterContentPasteboardItem(representations: [
            OuterContentPasteboardRepresentation(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                                                 data: data)
        ])]
    }

    private func writeProcessSearchSelectionToPasteboard(cut: Bool) {
        let items = processSearchPasteboardItems()
        guard !items.isEmpty else { return }
        outerframeHost.requestPasteboardWrite(items: items) { [weak self] granted in
            guard granted, cut else { return }
            self?.deleteProcessSearchSelection()
        }
    }

    private func readPasteboardIntoProcessSearch() {
        outerframeHost.requestPasteboardRead(typeIdentifiers: processSearchPasteboardTypeIdentifiers) { [weak self] granted, items in
            guard granted else { return }
            self?.insertProcessSearchPasteboardItems(items)
        }
    }

    private func insertProcessSearchPasteboardItems(_ items: [OuterContentPasteboardItem]) {
        guard processSearchFocused else { return }
        for item in items {
            for representation in item.representations {
                if representation.typeIdentifier == NSPasteboard.PasteboardType.string.rawValue,
                   let string = String(data: representation.data, encoding: .utf8) {
                    insertProcessSearchText(string, replacementRange: nil)
                    return
                }
                if representation.typeIdentifier == NSPasteboard.PasteboardType.rtf.rawValue,
                   let attributed = NSAttributedString(rtf: representation.data, documentAttributes: nil) {
                    insertProcessSearchText(attributed.string, replacementRange: nil)
                    return
                }
            }
        }
    }

    private func updateTextInputState() {
        let inputMode: OuterframeContentInputMode = processSearchFocused ? [.textInput, .rawKeys] : .rawKeys
        outerframeHost.setInputMode(inputMode)
        let hasSelection = processSearchSelectionRange() != nil
        outerframeHost.setEditingCapabilities(canCopy: processSearchFocused && hasSelection,
                                              canCut: processSearchFocused && hasSelection)
        outerframeHost.setAcceptedPasteboardPasteTypes(processSearchFocused ? processSearchPasteboardTypeIdentifiers : [])
        guard processSearchFocused, showingSetup else {
            outerframeHost.sendTextInputGeometryUpdate(nil)
            return
        }
        guard !hasSelection else {
            outerframeHost.sendTextInputGeometryUpdate(nil)
            return
        }
        let caretFrame = processSearchCaretRect()
        let rootCaretFrame = processSearchLayer.convert(caretFrame, to: rootLayer)
        let topLeftY = rootLayer.bounds.height - rootCaretFrame.origin.y - rootCaretFrame.height
        let geometry = OuterframeContentTextInputGeometry(fieldID: Self.processSearchFieldID,
                                                          rect: CGRect(x: rootCaretFrame.origin.x,
                                                                       y: topLeftY,
                                                                       width: rootCaretFrame.width,
                                                                       height: rootCaretFrame.height))
        outerframeHost.sendTextInputGeometryUpdate(geometry)
    }

    private var processSearchPasteboardTypeIdentifiers: [String] {
        [
            NSPasteboard.PasteboardType.string.rawValue,
            NSPasteboard.PasteboardType.rtf.rawValue
        ]
    }

    private func utf16Offset(forCharacterIndex index: Int, in text: String) -> Int {
        let clamped = max(0, min(index, text.count))
        let stringIndex = text.index(text.startIndex, offsetBy: clamped)
        return text[text.startIndex..<stringIndex].utf16.count
    }

    private func characterIndex(forUTF16 offset: Int, in text: String) -> Int {
        let clamped = max(0, min(offset, text.utf16.count))
        let stringIndex = String.Index(utf16Offset: clamped, in: text)
        return text.distance(from: text.startIndex, to: stringIndex)
    }

    private func updateTimeline() {
        guard timelineLayer.superlayer != nil else { return }
        appearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            timelineLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            timelineLayer.isHidden = showingSetup

            guard !showingSetup else {
                CATransaction.commit()
                return
            }

            let title = makeTextLayer(size: 12, weight: .medium)
            title.string = "CPU Usage"
            title.foregroundColor = NSColor.secondaryLabelColor.cgColor
            title.frame = CGRect(x: 18, y: timelineLayer.bounds.height - 26, width: max(timelineLayer.bounds.width - 36, 1), height: 16)
            timelineLayer.addSublayer(title)

            let chartRect = timelineChartRect()
            let track = CALayer()
            track.frame = chartRect
            track.backgroundColor = timelineTrackColor.cgColor
            timelineLayer.addSublayer(track)

            if isRecording, lastProfile == nil {
                let empty = makeTextLayer(size: 13, weight: .regular)
                empty.string = "Recording in progress..."
                empty.foregroundColor = NSColor.secondaryLabelColor.cgColor
                empty.frame = CGRect(x: chartRect.minX + 10, y: chartRect.midY - 8, width: max(chartRect.width - 20, 1), height: 16)
                timelineLayer.addSublayer(empty)
                CATransaction.commit()
                return
            }

            guard let profile = lastProfile, !profile.timeline.isEmpty else {
                let empty = makeTextLayer(size: 13, weight: .regular)
                empty.string = "Select a trace to see CPU activity."
                empty.foregroundColor = NSColor.secondaryLabelColor.cgColor
                empty.frame = CGRect(x: chartRect.minX + 10, y: chartRect.midY - 8, width: max(chartRect.width - 20, 1), height: 16)
                timelineLayer.addSublayer(empty)
                CATransaction.commit()
                return
            }

            let maxCPU = max(profile.timeline.map(\.cpuPercent).max() ?? 0, 1)
            let duration = max(Double(profile.duration), profile.timeline.last?.end ?? 1)
            for bucket in profile.timeline {
                let x0 = chartRect.minX + CGFloat(bucket.start / duration) * chartRect.width
                let x1 = chartRect.minX + CGFloat(bucket.end / duration) * chartRect.width
                let barWidth = max(x1 - x0 - 1, 1)
                let normalized = min(max(bucket.cpuPercent / maxCPU, 0), 1)
                let barHeight = max(CGFloat(normalized) * chartRect.height, bucket.samples > 0 ? 2 : 0)
                let bar = CALayer()
                bar.frame = CGRect(x: x0, y: chartRect.minY, width: barWidth, height: barHeight)
                bar.backgroundColor = timelineBarColor.cgColor
                timelineLayer.addSublayer(bar)
            }

            let range = selectedRange ?? 0...duration
            let lowerX = chartRect.minX + CGFloat(range.lowerBound / duration) * chartRect.width
            let upperX = chartRect.minX + CGFloat(range.upperBound / duration) * chartRect.width
            let overlay = CALayer()
            overlay.frame = CGRect(x: min(lowerX, upperX),
                                   y: chartRect.minY,
                                   width: max(abs(upperX - lowerX), 2),
                                   height: chartRect.height)
            overlay.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(isDarkMode ? 0.28 : 0.18).cgColor
            overlay.borderColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.68).cgColor
            overlay.borderWidth = 1
            timelineLayer.addSublayer(overlay)

            let label = makeTextLayer(size: 12, weight: .regular, alignment: .right)
            let rangeDuration = max(range.upperBound - range.lowerBound, 0)
            label.string = "\(formatDuration(range.lowerBound)) - \(formatDuration(range.upperBound)) selected (\(formatDuration(rangeDuration)))"
            label.foregroundColor = NSColor.secondaryLabelColor.cgColor
            label.frame = CGRect(x: 18, y: 10, width: max(timelineLayer.bounds.width - 36, 1), height: 16)
            timelineLayer.addSublayer(label)

            CATransaction.commit()
        }
    }

    private func timelineChartRect() -> CGRect {
        CGRect(x: 18,
               y: 34,
               width: max(timelineLayer.bounds.width - 36, 1),
               height: max(timelineLayer.bounds.height - 66, 24))
    }

    private func timeForTimelinePoint(_ point: CGPoint) -> Double? {
        guard let profile = lastProfile else { return nil }
        let rect = timelineChartRect().insetBy(dx: -8, dy: -10)
        guard rect.contains(point) else { return nil }
        let chart = timelineChartRect()
        let duration = max(Double(profile.duration), profile.timeline.last?.end ?? 1)
        let normalized = min(max((point.x - chart.minX) / max(chart.width, 1), 0), 1)
        return Double(normalized) * duration
    }

    private func updateFlameGraph() {
        guard flameLayer.superlayer != nil else { return }
        appearance.performAsCurrentDrawingAppearance {
            hideTooltip()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            flameLayer.isHidden = showingSetup
            flameDecorationLayer.frame = flameLayer.bounds
            flameScrollbarLayer.frame = flameLayer.bounds
            flameDecorationLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            flameBoxContentLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            flameTextOverlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            flameScrollbarLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            flameViewportLayer.isHidden = true
            flameHitRegions.removeAll()
            flameLayerItems.removeAll()
            flameTotalSamples = 0

            guard !showingSetup else {
                flameContentSize = .zero
                CATransaction.commit()
                return
            }

            guard let profile = lastProfile else {
                if isRecording {
                    addRecordingPlaceholder()
                } else {
                    let empty = makeTextLayer(size: 14, weight: .regular)
                    empty.string = "Select a trace to see sampled call stacks."
                    empty.foregroundColor = NSColor.secondaryLabelColor.cgColor
                    empty.frame = CGRect(x: 22, y: flameLayer.bounds.height - 42, width: max(flameLayer.bounds.width - 44, 1), height: 18)
                    flameDecorationLayer.addSublayer(empty)
                }
                flameContentSize = .zero
                CATransaction.commit()
                return
            }

            let root = FlameNode(frame: StackFrame(symbol: "root", binary: ""))
            for folded in profile.folded {
                guard !folded.stack.isEmpty, folded.count > 0 else { continue }
                root.count += folded.count
                var node = root
                for frame in folded.stack {
                    node = node.child(frame: frame)
                    node.count += folded.count
                }
            }

            if root.count == 0 {
                let empty = makeTextLayer(size: 14, weight: .regular)
                let detail = profile.status?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let detail, !detail.isEmpty {
                    empty.string = detail
                } else if !profile.scriptError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let scriptError = profile.scriptError.trimmingCharacters(in: .whitespacesAndNewlines)
                    let firstLine = scriptError.components(separatedBy: .newlines).first ?? scriptError
                    empty.string = "perf could not decode stack samples: \(firstLine)"
                } else {
                    empty.string = "No stack samples captured. Try a process that is actively using CPU."
                }
                empty.foregroundColor = NSColor.secondaryLabelColor.cgColor
                empty.frame = CGRect(x: 22, y: flameLayer.bounds.height - 48, width: max(flameLayer.bounds.width - 44, 1), height: 24)
                flameDecorationLayer.addSublayer(empty)
                flameContentSize = .zero
                CATransaction.commit()
                return
            }

            flameTotalSamples = root.count
            let title = makeTextLayer(size: 13, weight: .medium)
            title.string = "Profile  pid \(profile.pid), \(formatDuration(Double(profile.duration))) at \(profile.frequency) Hz"
            title.foregroundColor = NSColor.secondaryLabelColor.cgColor
            title.frame = CGRect(x: 18, y: flameLayer.bounds.height - 30, width: max(flameLayer.bounds.width - 36, 1), height: 16)
            flameDecorationLayer.addSublayer(title)

            let graphRect = flameGraphViewportRect()
            flameViewportLayer.frame = graphRect
            flameViewportLayer.backgroundColor = NSColor.clear.cgColor
            flameViewportLayer.isHidden = false

            buildFlameItems(of: root,
                            xFraction: 0,
                            widthFraction: 1,
                            depth: 0,
                            total: root.count,
                            targetLayer: flameBoxContentLayer)
            updateFlameContentSizeForCurrentZoom(viewport: graphRect)
            flameLaidOutZoom = flameZoom
            clampFlameScroll()
            updateFlameItemFrames()
            updateFlameScrollPosition()
            CATransaction.commit()
        }
    }

    private var flameGraphRowHeight: CGFloat { 31 }

    private func addRecordingPlaceholder() {
        let title = makeTextLayer(size: 18, weight: .semibold)
        title.string = "Recording"
        title.frame = CGRect(x: 22, y: flameLayer.bounds.height - 62, width: max(flameLayer.bounds.width - 44, 1), height: 24)
        flameDecorationLayer.addSublayer(title)

        let target = activeRecordingPID.map { "pid \($0)" } ?? selectedProcessSubtitle
        let frequency = activeRecordingFrequency.map { " at \($0) Hz" } ?? ""
        let elapsed: String
        if let recordingStartedAt {
            elapsed = "  \(formatDuration(Date().timeIntervalSince(recordingStartedAt))) elapsed"
        } else {
            elapsed = ""
        }

        let subtitle = makeTextLayer(size: 13, weight: .regular)
        subtitle.string = "\(target)\(frequency). Press Stop to build the profile.\(elapsed)"
        subtitle.foregroundColor = NSColor.secondaryLabelColor.cgColor
        subtitle.frame = CGRect(x: 22, y: flameLayer.bounds.height - 86, width: max(flameLayer.bounds.width - 44, 1), height: 18)
        flameDecorationLayer.addSublayer(subtitle)
    }

    private func flameGraphViewportRect() -> CGRect {
        CGRect(x: 18,
               y: 18,
               width: max(flameLayer.bounds.width - 36, 1),
               height: max(flameLayer.bounds.height - 62, 1))
    }

    private func maxFlameDepth(_ node: FlameNode) -> Int {
        guard !node.children.isEmpty else { return 0 }
        return 1 + (node.children.values.map(maxFlameDepth).max() ?? 0)
    }

    private func buildFlameItems(of node: FlameNode,
                                 xFraction: CGFloat,
                                 widthFraction: CGFloat,
                                 depth: Int,
                                 total: Int,
                                 targetLayer: CALayer) {
        guard widthFraction > 0, depth < 32 else { return }
        var childXFraction = xFraction
        let children = node.children.values.sorted {
            if $0.count == $1.count { return $0.frame.symbol < $1.frame.symbol }
            return $0.count > $1.count
        }
        for child in children {
            let childWidthFraction = widthFraction * CGFloat(child.count) / CGFloat(max(total, 1))
            if childWidthFraction <= 0 { continue }
            buildFlameItem(child,
                           depth: depth,
                           xFraction: childXFraction,
                           widthFraction: childWidthFraction,
                           targetLayer: targetLayer)
            buildFlameItems(of: child,
                            xFraction: childXFraction,
                            widthFraction: childWidthFraction,
                            depth: depth + 1,
                            total: child.count,
                            targetLayer: targetLayer)
            childXFraction += childWidthFraction
        }
    }

    private func buildFlameItem(_ node: FlameNode,
                                depth: Int,
                                xFraction: CGFloat,
                                widthFraction: CGFloat,
                                targetLayer: CALayer) {
        let box = CALayer()
        box.backgroundColor = colorForBinary(node.frame.binary.isEmpty ? node.frame.symbol : node.frame.binary).cgColor
        box.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        box.borderWidth = 0.5
        targetLayer.addSublayer(box)
        flameLayerItems.append(FlameLayerItem(node: node,
                                              depth: depth,
                                              xFraction: xFraction,
                                              widthFraction: widthFraction,
                                              boxLayer: box))
    }

    private func updateFlameItemFrames() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard flameContentSize.width > 0, flameContentSize.height > 0 else {
            flameHitRegions.removeAll()
            return
        }
        let rowHeight = flameGraphRowHeight
        flameHitRegions.removeAll(keepingCapacity: true)
        for item in flameLayerItems {
            let rawX = item.xFraction * flameContentSize.width
            let rawWidth = item.widthFraction * flameContentSize.width
            let frame = CGRect(x: rawX,
                               y: flameContentSize.height - CGFloat(item.depth + 1) * rowHeight,
                               width: max(rawWidth - 1, 1),
                               height: rowHeight - 2)
            item.frame = frame
            item.boxLayer.frame = frame
            item.boxLayer.isHidden = rawWidth < 1
            flameHitRegions.append(FlameHitRegion(frame: frame,
                                                  symbol: item.node.frame.symbol,
                                                  binary: item.node.frame.binary,
                                                  count: item.node.count,
                                                  depth: item.depth,
                                                  total: flameTotalSamples))

        }
        updateFlameTextOverlayFrames()
    }

    private func updateFlameTextOverlayFrames() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard flameContentSize.width > 0, flameContentSize.height > 0 else {
            for item in flameLayerItems {
                item.symbolClipLayer?.isHidden = true
                item.binaryClipLayer?.isHidden = true
            }
            return
        }

        let rowHeight = flameGraphRowHeight
        flameTextOverlayLayer.bounds = CGRect(origin: .zero, size: flameContentSize)

        for item in flameLayerItems {
            let rawX = item.xFraction * flameContentSize.width
            let rawWidth = item.widthFraction * flameContentSize.width
            let frame = CGRect(x: rawX,
                               y: flameContentSize.height - CGFloat(item.depth + 1) * rowHeight,
                               width: max(rawWidth - 1, 1),
                               height: rowHeight - 2)

            if frame.width >= 34 {
                let clipLayer = item.symbolClipLayer ?? makeFlameTextClipLayer(for: item, kind: .symbol)
                let labelFrame = CGRect(x: frame.minX + 5,
                                        y: frame.minY + (item.node.frame.binary.isEmpty || frame.height < 25 ? 5 : 12),
                                        width: max(frame.width - 10, 1),
                                        height: 13)
                clipLayer.isHidden = false
                setFrameIfNeeded(clipLayer, labelFrame)
            } else {
                item.symbolClipLayer?.isHidden = true
            }

            if !item.node.frame.binary.isEmpty, frame.width >= 54, frame.height >= 25 {
                let clipLayer = item.binaryClipLayer ?? makeFlameTextClipLayer(for: item, kind: .binary)
                let labelFrame = CGRect(x: frame.minX + 5,
                                        y: frame.minY + 4,
                                        width: max(frame.width - 10, 1),
                                        height: 11)
                clipLayer.isHidden = false
                setFrameIfNeeded(clipLayer, labelFrame)
            } else {
                item.binaryClipLayer?.isHidden = true
            }
        }
    }

    private enum FlameTextKind {
        case symbol
        case binary
    }

    private func makeFlameTextClipLayer(for item: FlameLayerItem, kind: FlameTextKind) -> CALayer {
        let clipLayer = CALayer()
        clipLayer.masksToBounds = true
        clipLayer.contentsScale = 2

        switch kind {
        case .symbol:
            let textLayer = makeTextLayer(size: 11, weight: .medium)
            textLayer.string = item.node.frame.symbol
            textLayer.foregroundColor = NSColor.white.cgColor
            textLayer.truncationMode = .none
            textLayer.frame = CGRect(x: 0,
                                     y: 0,
                                     width: flameTextNaturalWidth(item.node.frame.symbol, size: 11, weight: .medium),
                                     height: 13)
            clipLayer.addSublayer(textLayer)
            flameTextOverlayLayer.addSublayer(clipLayer)
            item.symbolLayer = textLayer
            item.symbolClipLayer = clipLayer

        case .binary:
            let textLayer = makeTextLayer(size: 9, weight: .regular)
            textLayer.string = item.node.frame.binary
            textLayer.foregroundColor = NSColor.white.withAlphaComponent(0.68).cgColor
            textLayer.truncationMode = .none
            textLayer.frame = CGRect(x: 0,
                                     y: 0,
                                     width: flameTextNaturalWidth(item.node.frame.binary, size: 9, weight: .regular),
                                     height: 11)
            clipLayer.addSublayer(textLayer)
            flameTextOverlayLayer.addSublayer(clipLayer)
            item.binaryLayer = textLayer
            item.binaryClipLayer = clipLayer
        }

        return clipLayer
    }

    private func flameTextNaturalWidth(_ text: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let font = NSFont.systemFont(ofSize: size, weight: weight)
        let measured = (text as NSString).size(withAttributes: [.font: font]).width
        return max(ceil(measured) + 6, 1)
    }

    private func setFrameIfNeeded(_ layer: CALayer, _ frame: CGRect) {
        let rounded = CGRect(x: (frame.origin.x * 2).rounded() / 2,
                             y: (frame.origin.y * 2).rounded() / 2,
                             width: (frame.width * 2).rounded() / 2,
                             height: (frame.height * 2).rounded() / 2)
        if layer.frame != rounded {
            layer.frame = rounded
        }
    }

    private func updateFlameContentSizeForCurrentZoom(viewport: CGRect) {
        guard !flameLayerItems.isEmpty else {
            flameContentSize = .zero
            return
        }
        let rowHeight = flameGraphRowHeight
        let depth = (flameLayerItems.map(\.depth).max() ?? 0) + 1
        flameContentSize = CGSize(width: max(viewport.width * flameZoom, viewport.width),
                                  height: max(CGFloat(depth) * rowHeight, viewport.height))
    }

    private func flameLaidOutContentSize(viewport: CGRect) -> CGSize {
        guard !flameLayerItems.isEmpty else { return .zero }
        let rowHeight = flameGraphRowHeight
        let depth = (flameLayerItems.map(\.depth).max() ?? 0) + 1
        return CGSize(width: max(viewport.width * flameLaidOutZoom, viewport.width),
                      height: max(CGFloat(depth) * rowHeight, viewport.height))
    }

    private func flameLiveZoomScale(viewport: CGRect) -> CGFloat {
        let laidOutSize = flameLaidOutContentSize(viewport: viewport)
        guard laidOutSize.width > 0 else { return 1 }
        return flameContentSize.width / laidOutSize.width
    }

    private func commitFlameZoomLayout() {
        guard !flameLayerItems.isEmpty else { return }
        let viewport = flameGraphViewportRect()
        updateFlameContentSizeForCurrentZoom(viewport: viewport)
        flameLaidOutZoom = flameZoom
        updateFlameItemFrames()
    }

    private func updateFlameScrollPosition() {
        guard flameLayer.superlayer != nil else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let viewport = flameGraphViewportRect()
        let laidOutSize = flameLaidOutContentSize(viewport: viewport)
        let scale = flameLiveZoomScale(viewport: viewport)
        flameDecorationLayer.frame = flameLayer.bounds
        flameScrollbarLayer.frame = flameLayer.bounds
        flameViewportLayer.frame = viewport
        flameBoxContentLayer.bounds = CGRect(origin: .zero, size: laidOutSize)
        flameBoxContentLayer.position = CGPoint(x: -flameHorizontalScroll,
                                                y: viewport.height - laidOutSize.height + flameVerticalScroll)
        flameBoxContentLayer.transform = CATransform3DMakeScale(scale, 1, 1)
        flameTextOverlayLayer.bounds = CGRect(origin: .zero, size: flameContentSize)
        flameTextOverlayLayer.position = CGPoint(x: -flameHorizontalScroll,
                                                 y: viewport.height - flameContentSize.height + flameVerticalScroll)
        flameTextOverlayLayer.transform = CATransform3DIdentity
        addFlameScrollbars(viewport: viewport)
        CATransaction.commit()
    }

    private func addFlameScrollbars(viewport: CGRect) {
        flameScrollbarLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let hasHorizontalOverflow = flameContentSize.width > viewport.width + 1
        let hasVerticalOverflow = flameContentSize.height > viewport.height + 1
        guard hasHorizontalOverflow || hasVerticalOverflow else { return }

        let thickness: CGFloat = 9
        let inset: CGFloat = 5
        let corner: CGFloat = thickness * 0.5

        if hasVerticalOverflow {
            let trackHeight = max(viewport.height, 1)
            let trackFrame = CGRect(x: min(viewport.maxX + inset, flameLayer.bounds.maxX - inset - thickness),
                                    y: viewport.minY,
                                    width: thickness,
                                    height: trackHeight)
            let track = CALayer()
            track.frame = trackFrame
            track.cornerRadius = corner
            track.backgroundColor = resolvedCGColor(scrollbarTrackColor)
            flameScrollbarLayer.addSublayer(track)

            let proportion = min(max(viewport.height / max(flameContentSize.height, 1), 0), 1)
            let thumbHeight = min(max(trackHeight * proportion, 18), trackHeight)
            let range = max(trackHeight - thumbHeight, 0)
            let progress = flameVerticalScroll / max(flameContentSize.height - viewport.height, 1)
            let thumb = CALayer()
            thumb.frame = CGRect(x: trackFrame.minX,
                                 y: trackFrame.maxY - thumbHeight - range * progress,
                                 width: thickness,
                                 height: thumbHeight)
            thumb.cornerRadius = corner
            thumb.backgroundColor = resolvedCGColor(scrollbarThumbColor)
            flameScrollbarLayer.addSublayer(thumb)
        }

        if hasHorizontalOverflow {
            let trackWidth = max(viewport.width, 1)
            let trackFrame = CGRect(x: viewport.minX,
                                    y: max(flameLayer.bounds.minY + inset, viewport.minY - inset - thickness),
                                    width: trackWidth,
                                    height: thickness)
            let track = CALayer()
            track.frame = trackFrame
            track.cornerRadius = corner
            track.backgroundColor = resolvedCGColor(scrollbarTrackColor)
            flameScrollbarLayer.addSublayer(track)

            let proportion = min(max(viewport.width / max(flameContentSize.width, 1), 0), 1)
            let thumbWidth = min(max(trackWidth * proportion, 24), trackWidth)
            let range = max(trackWidth - thumbWidth, 0)
            let progress = flameHorizontalScroll / max(flameContentSize.width - viewport.width, 1)
            let thumb = CALayer()
            thumb.frame = CGRect(x: trackFrame.minX + range * progress,
                                 y: trackFrame.minY,
                                 width: thumbWidth,
                                 height: thickness)
            thumb.cornerRadius = corner
            thumb.backgroundColor = resolvedCGColor(scrollbarThumbColor)
            flameScrollbarLayer.addSublayer(thumb)
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        if seconds < 1 {
            return "\(Int((seconds * 1000).rounded())) ms"
        }
        if seconds < 60 {
            return String(format: "%.2f s", seconds)
        }
        let whole = Int(seconds.rounded())
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private func colorForBinary(_ binary: String) -> NSColor {
        var hash: UInt32 = 2_166_136_261
        for scalar in binary.unicodeScalars {
            hash = hash &* 16777619 ^ UInt32(scalar.value)
        }
        let hue = CGFloat(hash % 360) / 360.0
        return NSColor(calibratedHue: hue,
                       saturation: isDarkMode ? 0.46 : 0.58,
                       brightness: isDarkMode ? 0.58 : 0.72,
                       alpha: 1)
    }

    private var isDarkMode: Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var toolbarColor: NSColor {
        isDarkMode ? NSColor.controlBackgroundColor.withAlphaComponent(0.72) : NSColor.controlBackgroundColor
    }

    private var sidebarBackgroundColor: NSColor {
        isDarkMode ? NSColor.controlBackgroundColor.withAlphaComponent(0.64) : NSColor.textBackgroundColor.withAlphaComponent(0.72)
    }

    private var tableBackgroundColor: NSColor {
        isDarkMode ? NSColor.controlBackgroundColor.withAlphaComponent(0.62) : NSColor.textBackgroundColor
    }

    private var searchFieldBackgroundColor: NSColor {
        isDarkMode ? NSColor.textBackgroundColor.withAlphaComponent(0.44) : NSColor.textBackgroundColor
    }

    private var timelineTrackColor: NSColor {
        isDarkMode ? NSColor.controlBackgroundColor.withAlphaComponent(0.78) : NSColor.controlBackgroundColor
    }

    private var timelineBarColor: NSColor {
        isDarkMode ? NSColor.systemTeal.withAlphaComponent(0.82) : NSColor.systemBlue.withAlphaComponent(0.72)
    }

    private var tooltipBackgroundColor: NSColor {
        isDarkMode ? NSColor.windowBackgroundColor.withAlphaComponent(0.96) : NSColor.windowBackgroundColor.withAlphaComponent(0.98)
    }

    private var scrollbarTrackColor: NSColor {
        isDarkMode
            ? NSColor(calibratedWhite: 1.0, alpha: 0.10)
            : NSColor(calibratedWhite: 0.0, alpha: 0.08)
    }

    private var scrollbarThumbColor: NSColor {
        isDarkMode
            ? NSColor(calibratedWhite: 1.0, alpha: 0.42)
            : NSColor(calibratedWhite: 0.0, alpha: 0.34)
    }

    private func resolvedCGColor(_ color: NSColor) -> CGColor {
        var cgColor = color.cgColor
        appearance.performAsCurrentDrawingAppearance {
            cgColor = color.cgColor
        }
        return cgColor
    }

    private func clampProcessScroll() {
        let viewportHeight = max(processViewportLayer.bounds.height, processTableFrame().insetBy(dx: 1, dy: 1).height, 1)
        let count = filteredProcessIndices.isEmpty && !processes.isEmpty && processSearchText.isEmpty ? processes.count : filteredProcessIndices.count
        let maxOffset = max(CGFloat(count) * rowHeight - viewportHeight, 0)
        processScroll = min(max(processScroll, 0), maxOffset)
    }

    private func clampTraceScroll() {
        let viewportHeight = max(traceViewportLayer.bounds.height, traceViewportFrame().height, 1)
        let maxOffset = max(CGFloat(traceRowCount()) * runRowHeight - viewportHeight, 0)
        traceScroll = min(max(traceScroll, 0), maxOffset)
    }

    private func resetFlameViewport() {
        flameVerticalScroll = 0
        flameHorizontalScroll = 0
        flameZoom = 1
        flameLaidOutZoom = 1
        flameContentSize = .zero
    }

    private func clampFlameScroll() {
        let viewport = flameGraphViewportRect()
        let maxHorizontal = max(flameContentSize.width - viewport.width, 0)
        let maxVertical = max(flameContentSize.height - viewport.height, 0)
        flameHorizontalScroll = min(max(flameHorizontalScroll, 0), maxHorizontal)
        flameVerticalScroll = min(max(flameVerticalScroll, 0), maxVertical)
        if flameZoom < 1 {
            flameZoom = 1
        } else if flameZoom > 16 {
            flameZoom = 16
        }
    }

    private func styleButton(_ layer: CALayer, enabled: Bool) {
        layer.cornerRadius = 6
        layer.borderWidth = 1
        layer.borderColor = NSColor.separatorColor.cgColor
        let background = isDarkMode ? NSColor.controlBackgroundColor.withAlphaComponent(0.82) : NSColor.controlBackgroundColor
        layer.backgroundColor = enabled ? background.cgColor : background.withAlphaComponent(0.45).cgColor
        layer.opacity = enabled ? 1 : 0.55
        for case let textLayer as CATextLayer in layer.sublayers ?? [] {
            textLayer.foregroundColor = NSColor.labelColor.cgColor
        }
    }

    private func styleRecordButton() {
        let enabled = !isBusy && (isRecording || selectedPID != nil)
        recordToggleButtonLayer.cornerRadius = 7
        recordToggleButtonLayer.borderWidth = 1
        recordToggleButtonLayer.borderColor = NSColor.separatorColor.cgColor
        recordToggleButtonLayer.backgroundColor = (isDarkMode ? NSColor.controlBackgroundColor.withAlphaComponent(0.82) : NSColor.controlBackgroundColor).cgColor
        recordToggleButtonLayer.opacity = enabled ? 1 : 0.55
        recordToggleButtonLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        let symbol = makeSymbolLayer(isRecording ? "stop.fill" : "record.circle",
                                     color: isRecording ? NSColor.labelColor : NSColor.systemRed)
        symbol.frame = CGRect(x: 8, y: 5, width: 20, height: 20)
        recordToggleButtonLayer.addSublayer(symbol)
    }

    private func makeButtonLabel(_ title: String) -> CATextLayer {
        let layer = makeTextLayer(size: 13, weight: .medium, alignment: .center)
        layer.string = title
        return layer
    }

    private func makeSymbolLayer(_ symbolName: String, color: NSColor) -> CALayer {
        let layer = CALayer()
        updateSymbolLayer(layer, symbolName: symbolName, color: color)
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = 2
        return layer
    }

    private func updateSymbolLayer(_ layer: CALayer, symbolName: String, color: NSColor) {
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return }
        image.isTemplate = true
        let size = NSSize(width: 24, height: 24)
        let rendered = NSImage(size: size)
        appearance.performAsCurrentDrawingAppearance {
            rendered.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: size),
                       from: .zero,
                       operation: .sourceOver,
                       fraction: 1)
            color.set()
            NSRect(origin: .zero, size: size).fill(using: .sourceIn)
            rendered.unlockFocus()
        }
        var rect = NSRect(origin: .zero, size: size)
        layer.contents = rendered.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = 2
    }

    private func makeTextLayer(size: CGFloat,
                               weight: NSFont.Weight,
                               alignment: CATextLayerAlignmentMode = .left) -> CATextLayer {
        let layer = CATextLayer()
        layer.font = NSFont.systemFont(ofSize: size, weight: weight)
        layer.fontSize = size
        layer.contentsScale = 2
        layer.truncationMode = .end
        layer.alignmentMode = alignment
        layer.foregroundColor = NSColor.labelColor.cgColor
        return layer
    }

    private func noImplicitLayerActions() -> [String: CAAction] {
        [
            "backgroundColor": NSNull(),
            "borderColor": NSNull(),
            "borderWidth": NSNull(),
            "bounds": NSNull(),
            "contents": NSNull(),
            "cornerRadius": NSNull(),
            "foregroundColor": NSNull(),
            "frame": NSNull(),
            "hidden": NSNull(),
            "isHidden": NSNull(),
            "opacity": NSNull(),
            "position": NSNull(),
            "string": NSNull()
        ]
    }
}
