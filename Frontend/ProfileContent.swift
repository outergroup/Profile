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

@MainActor
private final class FilePickerScrollbarDelegate: ScrollbarControllerDelegate {
    private weak var owner: ProfileHandler?

    init(owner: ProfileHandler) {
        self.owner = owner
    }

    func scrollbarDidChangeScrollOffset(_ offset: CGFloat) {
        owner?.setFilePickerScroll(offset)
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
    let containerID: String
    let startTime: UInt64

}

private struct PerfConfigResponse {
    let path: String
    let usable: Bool
    let message: String
    let machineUnsupported: Bool
}

private struct FilePickerResponse {
    let path: String
    let parent: String
    let entries: [FilePickerEntry]
}

private struct MachineUnsupportedTextLine {
    let text: String
    let range: Range<Int>
    let frame: CGRect
    let font: NSFont
}

private struct FilePickerEntry {
    let name: String
    let path: String
    let isDirectory: Bool
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

private final class TimelineBarsLayer: CALayer {
    private var profileID: UInt64?
    private var buckets: [TimelineBucket] = []
    private var timelineDuration: Double = 1
    private var maxCPU: Double = 100
    private var barColor: CGColor = NSColor.systemBlue.cgColor

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let source = layer as? TimelineBarsLayer {
            profileID = source.profileID
            buckets = source.buckets
            timelineDuration = source.timelineDuration
            maxCPU = source.maxCPU
            barColor = source.barColor
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(profileID: UInt64, buckets: [TimelineBucket], duration: Double, maxCPU: Double, barColor: CGColor) {
        var needsDisplay = false
        if self.profileID != profileID || self.buckets.count != buckets.count {
            self.profileID = profileID
            self.buckets = buckets
            needsDisplay = true
        }
        if self.timelineDuration != duration {
            self.timelineDuration = duration
            needsDisplay = true
        }
        if self.maxCPU != maxCPU {
            self.maxCPU = maxCPU
            needsDisplay = true
        }
        if !CFEqual(self.barColor, barColor) {
            self.barColor = barColor
            needsDisplay = true
        }
        if needsDisplay {
            setNeedsDisplay()
        }
    }

    override func draw(in context: CGContext) {
        guard bounds.width > 0, bounds.height > 0, timelineDuration > 0, maxCPU > 0 else { return }
        context.setFillColor(barColor)
        for bucket in buckets where bucket.samples > 0 {
            let x0 = CGFloat(bucket.start / timelineDuration) * bounds.width
            let x1 = CGFloat(bucket.end / timelineDuration) * bounds.width
            let barWidth = max(x1 - x0, 1)
            let normalized = min(max(bucket.cpuPercent / maxCPU, 0), 1)
            let barHeight = max(CGFloat(normalized) * bounds.height, 2)
            context.fill(CGRect(x: x0, y: 0, width: barWidth, height: barHeight))
        }
    }
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
    private static let perfConfigType: UInt32 = 5
    private static let filePickerType: UInt32 = 6

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
            let row = Int(rowsOffset) + index * 56
            guard let pid = reader.i32(at: row),
                  let ppid = reader.i32(at: row + 4),
                  let nameOffset = reader.u32(at: row + 8),
                  let nameLength = reader.u32(at: row + 12),
                  let commandOffset = reader.u32(at: row + 16),
                  let commandLength = reader.u32(at: row + 20),
                  let name = reader.string(offset: nameOffset, length: nameLength),
                  let command = reader.string(offset: commandOffset, length: commandLength) else { return nil }
            guard let containerOffset = reader.u32(at: row + 24),
                  let containerLength = reader.u32(at: row + 28),
                  let container = reader.string(offset: containerOffset, length: containerLength),
                  let idOffset = reader.u32(at: row + 32),
                  let idLength = reader.u32(at: row + 36),
                  let containerID = reader.string(offset: idOffset, length: idLength),
                  let startTime = reader.u64(at: row + 48) else { return nil }
            let displayName = containerID == "host" ? name : "\(name) — \(container)"
            processes.append(ProfileProcess(pid: Int(pid), ppid: Int(ppid), name: displayName, command: command,
                                            containerID: containerID, startTime: startTime))
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

    static func decodePerfConfig(_ data: Data) -> PerfConfigResponse? {
        guard let reader = reader(data, type: perfConfigType),
              let usable = reader.u32(at: 16),
              let pathOffset = reader.u32(at: 20),
              let pathLength = reader.u32(at: 24),
              let messageOffset = reader.u32(at: 28),
              let messageLength = reader.u32(at: 32),
              let path = reader.string(offset: pathOffset, length: pathLength),
              let message = reader.string(offset: messageOffset, length: messageLength) else { return nil }
        let headerSize = reader.u32(at: 36) ?? 44
        let machineUnsupported = headerSize >= 48 ? ((reader.u32(at: 44) ?? 0) != 0) : false
        return PerfConfigResponse(path: path,
                                  usable: usable != 0,
                                  message: message,
                                  machineUnsupported: machineUnsupported)
    }

    static func decodeFilePicker(_ data: Data) -> FilePickerResponse? {
        guard let reader = reader(data, type: filePickerType),
              let pathOffset = reader.u32(at: 16),
              let pathLength = reader.u32(at: 20),
              let parentOffset = reader.u32(at: 24),
              let parentLength = reader.u32(at: 28),
              let count = reader.u32(at: 32),
              let rowsOffset = reader.u32(at: 36),
              let path = reader.string(offset: pathOffset, length: pathLength),
              let parent = reader.string(offset: parentOffset, length: parentLength) else { return nil }
        var entries: [FilePickerEntry] = []
        for index in 0..<Int(count) {
            let row = Int(rowsOffset) + index * 32
            guard let nameOffset = reader.u32(at: row),
                  let nameLength = reader.u32(at: row + 4),
                  let entryPathOffset = reader.u32(at: row + 8),
                  let entryPathLength = reader.u32(at: row + 12),
                  let flags = reader.u32(at: row + 16),
                  let name = reader.string(offset: nameOffset, length: nameLength),
                  let entryPath = reader.string(offset: entryPathOffset, length: entryPathLength) else { return nil }
            entries.append(FilePickerEntry(name: name, path: entryPath, isDirectory: flags & 1 != 0))
        }
        return FilePickerResponse(path: path, parent: parent, entries: entries)
    }
}

@MainActor
private final class ProfileHandler: NSObject, OuterframeHostDelegate, SingleLineTextInputControllerDelegate {
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
    private let filePickerOverlayLayer = CALayer()
    private let filePickerListLayer = CALayer()
    private let filePickerRowsContentLayer = CALayer()
    private let filePickerStatusLayer = CALayer()
    private let traceViewportLayer = CALayer()
    private let traceContentLayer = CALayer()
    private let traceScrollbarLayer = CALayer()
    private let timelineLayer = CALayer()
    private let timelineBarsLayer = TimelineBarsLayer()
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
    private let machineUnsupportedOverlayLayer = CALayer()

    private var currentSize = CGSize(width: 1100, height: 720)
    private var appearance = NSAppearance.currentDrawing()
    private var urlSession: URLSession?
    private var processesEndpoint: URL?
    private var profileStartEndpoint: URL?
    private var profileStopEndpoint: URL?
    private var profileListEndpoint: URL?
    private var profileRangeEndpoint: URL?
    private var profileDeleteEndpoint: URL?
    private var perfEndpoint: URL?
    private var filePickerEndpoint: URL?
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
    private var processSearchMarkedRange: Range<Int>?
    private var processSearchPendingMarkedRange: Range<Int>?
    private var processSearchFocused = false
    private var perfPath = "perf"
    private var perfUsable = false
    private var perfMessage = ""
    private var perfMachineUnsupported = false
    private var perfSelectFrame = CGRect.zero
    private var perfPathFrame = CGRect.zero
    private var pendingFilePicker: FilePickerResponse?
    private var filePickerPanelFrame = CGRect.zero
    private var filePickerListFrame = CGRect.zero
    private var filePickerBreadcrumbFrame = CGRect.zero
    private var filePickerCancelFrame = CGRect.zero
    private var filePickerEntryFrames: [(frame: CGRect, entry: FilePickerEntry, index: Int)] = []
    private var filePickerBreadcrumbSegmentFrames: [(frame: CGRect, path: String)] = []
    private var filePickerVisibleRowLayers: [Int: CALayer] = [:]
    private var filePickerReusableRowLayers: [CALayer] = []
    private var filePickerSelectedIndex: Int?
    private var filePickerTypeaheadPrefix = ""
    private var filePickerTypeaheadLastUpdated: Date?
    private var filePickerScroll: CGFloat = 0
    private var filePickerContentHeight: CGFloat = 0
    private var filteredProcessIndices: [Int] = []
    private var machineUnsupportedPanelFrame = CGRect.zero
    private var machineUnsupportedTextLines: [MachineUnsupportedTextLine] = []
    private var machineUnsupportedSelectionAnchor: Int?
    private var machineUnsupportedSelectionFocus: Int?
    private var isSelectingMachineUnsupportedText = false
    private var machineUnsupportedContextMenuIDs = Set<UUID>()
    private var currentTraceURL: URL?
    private var showingSetup = true
    private var isBusy = false
    private var isRecording = false
    private var activeRecordingID: UInt64?
    private var activeRecordingPID: Int?
    private var activeRecordingFrequency: Int?
    private var recordingStartedAt: Date?
    private var profileRequestID = UUID()
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
    private var perfPathContextMenuIDs: Set<UUID> = []
    private var currentCursor: PluginCursorType = .arrow
    private lazy var filePickerScrollbarDelegate = FilePickerScrollbarDelegate(owner: self)
    private var filePickerScrollbarController: ScrollbarController<FilePickerScrollbarDelegate>?

    private let toolbarHeight: CGFloat = 52
    private let sidebarWidth: CGFloat = 240
    private let timelineHeight: CGFloat = 132
    private let rowHeight: CGFloat = 30
    private let filePickerRowHeight: CGFloat = 28
    private let runRowHeight: CGFloat = 56
    private let horizontalInset: CGFloat = 14
    private static let processSearchFieldID = UUID()
    private static let perfPathFieldID = UUID()
    private let processSearchCaretBlinkAnimationKey = "processSearchCaretBlink"
    private lazy var perfPathInputController: SingleLineTextInputController<ProfileHandler> = {
        let controller = SingleLineTextInputController<ProfileHandler>(
            identifier: Self.perfPathFieldID,
            initialText: perfPath,
            acceptedPasteboardTypeIdentifiers: processSearchPasteboardTypeIdentifiers
        )
        controller.delegate = self
        controller.onSubmit = { [weak self] in
            self?.commitPerfPathInput()
        }
        return controller
    }()

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
            outerframeHost.setTitle("Profile")
            outerframeHost.setIcon(.bundleResource(path: "Contents/Resources/app-icon.png"))
            appearance = arguments.appearance ?? appearance
            currentSize = arguments.contentSize ?? currentSize
            configureNetworking()
            configureLayersIfNeeded()
            updateColors()
            updateLayout()
            registerRootLayerIfNeeded()
            outerframeHost.setInputMode(.rawKeys)
            currentTraceURL = outerframeHost.pluginURL()
            restoreTraceURL(currentTraceURL)
            fetchProfiles()
            fetchProcesses()
            fetchPerfConfig()

        case .historyTraversal(_, let url):
            currentTraceURL = URL(string: url)
            restoreTraceURL(currentTraceURL)

        case .resizeContent(let size):
            currentSize = size
            clampProcessScroll()
            clampTraceScroll()
            updateLayout()

        case .systemAppearanceUpdate(let appearance):
            self.appearance = appearance
            updateColors()

        case .scrollWheelEvent(let point, let delta, _, _, _, let hasPreciseScrollingDeltas):
            guard !perfMachineUnsupported else { return }
            let multiplier: CGFloat = hasPreciseScrollingDeltas ? 1 : rowHeight
            if pendingFilePicker != nil {
                if filePickerListFrame.contains(point) {
                    setFilePickerScroll(filePickerScroll - delta.y * multiplier)
                }
            } else if showingSetup, processListLayer.frame.contains(point) {
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
            guard !perfMachineUnsupported else { return }
            handleMagnification(magnification, at: location)

        case .magnificationEnded(_, _, _, _):
            guard !perfMachineUnsupported else { return }
            clampFlameScroll()
            commitFlameZoomLayout()
            updateFlameScrollPosition()

        case .mouseDown(let point, let modifierFlags, let clickCount):
            if perfMachineUnsupported {
                if modifierFlags.contains(.control) {
                    showMachineUnsupportedContextMenu(at: point)
                    return
                }
                handleMachineUnsupportedMouseDown(at: point, clickCount: clickCount)
                return
            }
            if modifierFlags.contains(.control) {
                handleRightMouseDown(at: point)
                return
            }
            handleMouseDown(at: point, clickCount: clickCount)

        case .mouseDragged(let point, _):
            if perfMachineUnsupported {
                handleMachineUnsupportedMouseDragged(at: point)
                return
            }
            handleMouseDragged(at: point)

        case .mouseUp(let point, _):
            if perfMachineUnsupported {
                handleMachineUnsupportedMouseUp(at: point)
                return
            }
            handleMouseUp(at: point)

        case .mouseMoved(let point, _):
            if perfMachineUnsupported {
                setCursorIfNeeded(machineUnsupportedCharacterIndex(at: point) == nil ? .arrow : .iBeam)
                return
            }
            handleMouseMoved(at: point)

        case .keyDown(let keyCode, let characters, let charactersIgnoringModifiers, let modifierFlags, let isARepeat):
            if perfMachineUnsupported {
                handleMachineUnsupportedKeyDown(charactersIgnoringModifiers: charactersIgnoringModifiers,
                                                modifierFlags: modifierFlags)
                return
            }
            guard !perfMachineUnsupported else { return }
            handleKeyDown(keyCode: keyCode,
                          characters: characters,
                          charactersIgnoringModifiers: charactersIgnoringModifiers,
                          modifierFlags: modifierFlags,
                          isARepeat: isARepeat)

        case .textInput(let text, let hasReplacementRange, let replacementLocation, let replacementLength):
            guard !perfMachineUnsupported else { return }
            handleTextInput(text,
                            hasReplacementRange: hasReplacementRange,
                            replacementLocation: replacementLocation,
                            replacementLength: replacementLength)

        case .setMarkedText(let text, let selectedLocation, let selectedLength, let hasReplacementRange, let replacementLocation, let replacementLength):
            guard !perfMachineUnsupported else { return }
            handleSetMarkedText(text,
                                selectedLocation: Int(selectedLocation),
                                selectedLength: Int(selectedLength),
                                hasReplacementRange: hasReplacementRange,
                                replacementLocation: Int(replacementLocation),
                                replacementLength: Int(replacementLength))

        case .unmarkText:
            guard !perfMachineUnsupported else { return }
            handleUnmarkText()

        case .windowActiveUpdate(let isActive):
            if !isActive { perfPathInputController.breakUndoCoalescing() }

        case .textCommand(let command):
            guard !perfMachineUnsupported else { return }
            handleTextCommand(command)

        case .textInputFocus(let fieldID, let hasFocus):
            guard !perfMachineUnsupported else { return }
            handleTextInputFocus(fieldID: fieldID, hasFocus: hasFocus)

        case .setCursorPosition(let fieldID, let position, let modifySelection):
            guard !perfMachineUnsupported else { return }
            handleSetCursorPosition(fieldID: fieldID, position: position, modifySelection: modifySelection)

        case .rightMouseDown(let point, _, _):
            if perfMachineUnsupported {
                showMachineUnsupportedContextMenu(at: point)
                return
            }
            handleRightMouseDown(at: point)

        case .contextMenuItemSelected(let menuID, let itemID):
            if perfMachineUnsupported {
                handleMachineUnsupportedContextMenuSelection(menuID: menuID, itemID: itemID)
                return
            }
            handleContextMenuSelection(menuID: menuID, itemID: itemID)

        case .selectionToPasteboardCopyRequest(let requestID):
            outerframeHost.sendCopySelectedPasteboardResponse(requestID: requestID,
                                                              items: selectedPasteboardItems())

        case .selectionToPasteboardCutRequest(let requestID):
            guard !perfMachineUnsupported else {
                outerframeHost.sendCopySelectedPasteboardResponse(requestID: requestID, items: [])
                return
            }
            let items = selectedPasteboardItems()
            outerframeHost.sendCopySelectedPasteboardResponse(requestID: requestID,
                                                              items: items)
            if !items.isEmpty {
                cutFocusedSelection()
            }

        case .editCommandValidationRequest(let requestID, let commands):
            guard !perfMachineUnsupported else {
                outerframeHost.sendEditCommandValidationResponse(requestID: requestID,
                                                                 enabledCommands: enabledEditCommands(in: commands))
                return
            }
            outerframeHost.sendEditCommandValidationResponse(
                requestID: requestID,
                enabledCommands: enabledEditCommands(in: commands)
            )

        case .pasteboardContentPasted(let items):
            guard !perfMachineUnsupported else { return }
            insertPasteboardItemsIntoFocusedField(items)

        case .accessibilityAction(let identifier, let action, let value):
            performAccessibilityAction(identifier, action: action, value: value)

        case .accessibilityActionAndSnapshot(let requestID, let identifier, let action, let value):
            performAccessibilityAction(identifier, action: action, value: value)
            outerframeHost.sendAccessibilitySnapshotResponse(requestID: requestID, snapshot: accessibilitySnapshot())

        case .accessibilitySnapshotRequest(let requestID):
            outerframeHost.sendAccessibilitySnapshotResponse(requestID: requestID, snapshot: accessibilitySnapshot())

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
        let targetParts = (outerframeHost.pluginURL()?.path ?? "").split(separator: "/")
        let targetPrefix = targetParts.count >= 2 && targetParts[0] == "targets" ? "/targets/\(targetParts[1])" : ""

        processesEndpoint = URL(string: targetPrefix + "/api/processes", relativeTo: base)?.absoluteURL
        profileStartEndpoint = URL(string: targetPrefix + "/api/profile/start", relativeTo: base)?.absoluteURL
        profileStopEndpoint = URL(string: targetPrefix + "/api/profile/stop", relativeTo: base)?.absoluteURL
        profileListEndpoint = URL(string: targetPrefix + "/api/profiles", relativeTo: base)?.absoluteURL
        profileRangeEndpoint = URL(string: targetPrefix + "/api/profile/range", relativeTo: base)?.absoluteURL
        profileDeleteEndpoint = URL(string: targetPrefix + "/api/profile/delete", relativeTo: base)?.absoluteURL
        perfEndpoint = URL(string: targetPrefix + "/api/perf", relativeTo: base)?.absoluteURL
        filePickerEndpoint = URL(string: targetPrefix + "/api/file-picker", relativeTo: base)?.absoluteURL
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
        rootLayer.addSublayer(filePickerOverlayLayer)
        rootLayer.addSublayer(tooltipLayer)
        rootLayer.addSublayer(machineUnsupportedOverlayLayer)

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
        filePickerOverlayLayer.isHidden = true
        let filePickerScrollbar = ScrollbarController<FilePickerScrollbarDelegate>(appConnection: outerframeHost,
                                                                                  viewportLayer: filePickerListLayer,
                                                                                  appearance: appearance,
                                                                                  width: 10,
                                                                                  inset: 4,
                                                                                  scrollOffsetOrigin: .bottom)
        filePickerScrollbar.delegate = filePickerScrollbarDelegate
        filePickerScrollbarController = filePickerScrollbar
        machineUnsupportedOverlayLayer.isHidden = true
    }

    private func registerRootLayerIfNeeded() {
        guard !hasRegisteredLayer, let registerLayer = appConnection.registerLayer else { return }
        registerLayer(rootLayer)
        hasRegisteredLayer = true
    }

    private var accessibilityIDs: [String: UInt32] = [:]
    private var accessibilityActions: [UInt32: (ProfileHandler, OuterframeAccessibilityAction, String) -> Void] = [:]
    private var accessibilityNodes: [UInt32: OuterframeAccessibilityNode] = [:]
    private var accessibilityNotificationPending = false

    private func notifyAccessibilityChanged() {
        guard hasRegisteredLayer, !accessibilityNotificationPending else { return }
        accessibilityNotificationPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            accessibilityNotificationPending = false
            outerframeHost.notifyAccessibilityTreeChanged(.layoutChanged)
        }
    }

    private func accessibilityNode(_ key: String, role: OuterframeAccessibilityRole, frame: CGRect,
                                   label: String, value: String? = nil, hint: String? = nil,
                                   children: [OuterframeAccessibilityNode] = [], enabled: Bool = true,
                                   actions: OuterframeAccessibilityActions = [], selected: Bool = false,
                                   focused: Bool = false, rowIndex: Int? = nil, rowCount: Int? = nil,
                                   disclosureLevel: Int = 0, expanded: Bool? = nil, minimum: Double? = nil, maximum: Double? = nil,
                                   handler: ((ProfileHandler, OuterframeAccessibilityAction, String) -> Void)? = nil) -> OuterframeAccessibilityNode {
        let id: UInt32
        if let existing = accessibilityIDs[key] { id = existing }
        else { id = UInt32(accessibilityIDs.count + 1); accessibilityIDs[key] = id }
        let node = OuterframeAccessibilityNode(identifier: id, role: role, frame: frame, label: label,
            value: value, hint: hint, children: children, rowCount: rowCount, isEnabled: enabled,
            actions: actions, isFocused: focused, isSelected: selected, rowIndex: rowIndex,
            supportsActionSnapshot: true, isExpanded: expanded, disclosureLevel: disclosureLevel, minimumValue: minimum, maximumValue: maximum)
        accessibilityNodes[id] = node
        accessibilityActions[id] = handler
        return node
    }

    private func performAccessibilityAction(_ identifier: UInt32, action: OuterframeAccessibilityAction, value: String) {
        _ = accessibilitySnapshot()
        guard let node = accessibilityNodes[identifier], node.isEnabled, node.actions.supports(action),
              let handler = accessibilityActions[identifier] else { return }
        handler(self, action, value)
        notifyAccessibilityChanged()
    }

    private func accessibilitySnapshot() -> OuterframeAccessibilitySnapshot {
        accessibilityNodes.removeAll(keepingCapacity: true)
        accessibilityActions.removeAll(keepingCapacity: true)
        func frame(_ layer: CALayer) -> CGRect { rootLayer.convert(layer.bounds, from: layer) }
        if perfMachineUnsupported {
            return OuterframeAccessibilitySnapshot(rootNodes: [accessibilityNode("unsupported", role: .staticText,
                frame: machineUnsupportedPanelFrame, label: "Profiling unavailable",
                value: machineUnsupportedTextLines.map(\.text).joined(separator: "\n"))])
        }
        if let picker = pendingFilePicker {
            var children: [OuterframeAccessibilityNode] = []
            for segment in filePickerBreadcrumbSegmentFrames {
                children.append(accessibilityNode("picker-path/" + segment.path, role: .button, frame: segment.frame,
                    label: segment.path, actions: [.press]) { owner, _, _ in owner.fetchFilePicker(path: segment.path) })
            }
            let rows = filePickerEntryFrames.filter { $0.frame.intersects(filePickerListFrame) }.map { item in
                accessibilityNode("picker-entry/" + item.entry.path, role: .row, frame: item.frame,
                    label: item.entry.name, value: item.entry.isDirectory ? "Folder" : "File",
                    hint: "Open", actions: [.press, .focus], selected: filePickerSelectedIndex == item.index,
                    rowIndex: item.index) { owner, action, _ in
                        owner.filePickerSelectedIndex = item.index
                        if action == .press { owner.activateFilePickerEntry(item.entry) }
                        else { owner.updateFilePickerVisibleRows(rebuild: true) }
                    }
            }
            children.append(accessibilityNode("picker-list", role: .table, frame: filePickerListFrame, label: "Choose perf executable",
                children: rows, actions: [.scrollUp, .scrollDown], rowCount: picker.entries.count) { owner, action, _ in
                    owner.setFilePickerScroll(owner.filePickerScroll + (action == .scrollDown ? 1 : -1) * owner.filePickerListFrame.height * 0.8)
                })
            children.append(accessibilityNode("picker-cancel", role: .button, frame: filePickerCancelFrame, label: "Cancel",
                actions: [.press]) { owner, _, _ in owner.pendingFilePicker = nil; owner.renderFilePicker() })
            return OuterframeAccessibilitySnapshot(rootNodes: [accessibilityNode("picker", role: .dialog,
                frame: filePickerPanelFrame, label: "Choose perf executable", value: picker.path, children: children)])
        }
        var children = [accessibilityNode("status", role: .staticText, frame: frame(statusLayer), label: "Status", value: statusLayer.string as? String)]
        children.append(accessibilityNode("record", role: .button, frame: frame(recordToggleButtonLayer),
            label: isRecording ? "Stop recording" : "Start recording",
            enabled: !isBusy && (isRecording || (perfUsable && selectedPID != nil)), actions: [.press]) { owner, _, _ in
                if owner.isRecording { owner.stopRecording() } else { owner.startRecording() }
            })
        children.append(accessibilityNode("setup", role: .button, frame: sidebarLayer.convert(nextRecordingFrame(), to: rootLayer),
            label: "Next Recording", actions: [.press], selected: showingSetup) { owner, _, _ in
                let rect = owner.nextRecordingFrame()
                owner.handleSidebarClick(at: CGPoint(x: rect.midX, y: rect.midY))
            })
        var traceNodes: [OuterframeAccessibilityNode] = []
        for (index, trace) in traces.enumerated().reversed() {
            let rect = traceContentLayer.convert(traceFrame(visualIndex: activeRecordingTraceRowCount() + traces.count - 1 - index), to: rootLayer)
            guard rect.intersects(frame(traceViewportLayer)) else { continue }
            traceNodes.append(accessibilityNode("trace/\(trace.profileID)", role: .row, frame: rect,
                label: "Run \(trace.profileID)", value: "PID \(trace.pid), \(String(format: "%.2f", trace.duration)) seconds, \(trace.sampleCount) samples",
                actions: [.press, .focus, .showMenu], selected: selectedTraceID == trace.profileID, rowIndex: traces.count - 1 - index) { owner, action, _ in
                    if action == .showMenu {
                        owner.handleRightMouseDown(at: CGPoint(x: rect.midX, y: rect.midY))
                    } else if let current = owner.traces.firstIndex(where: { $0.profileID == trace.profileID }) { owner.selectTrace(at: current) }
                })
        }
        children.append(accessibilityNode("traces", role: .table, frame: frame(traceViewportLayer), label: "Recordings", children: traceNodes,
            actions: [.scrollUp, .scrollDown], rowCount: traces.count) { owner, action, _ in
                owner.traceScroll += (action == .scrollDown ? 1 : -1) * owner.traceViewportLayer.bounds.height * 0.8
                owner.clampTraceScroll(); owner.updateTraceScrollPosition()
            })
        if showingSetup {
            children.append(accessibilityNode("refresh", role: .button, frame: frame(refreshButtonLayer), label: "Refresh processes",
                enabled: !isBusy && !isRecording, actions: [.press]) { owner, _, _ in owner.fetchProcesses() })
            children.append(accessibilityNode("search", role: .textField, frame: frame(processSearchLayer), label: "Search processes",
                value: processSearchText, enabled: !isRecording, actions: [.focus, .setValue], focused: processSearchFocused) { owner, action, value in
                    owner.blurPerfPath(commit: true)
                    owner.focusProcessSearch(cursorPosition: owner.processSearchText.count, modifySelection: false)
                    if action == .setValue { owner.setProcessSearchText(value) }
                })
            let viewport = frame(processViewportLayer)
            var rows: [OuterframeAccessibilityNode] = []
            let table = processTableFrame()
            for (index, sourceIndex) in filteredProcessIndices.enumerated() {
                let rect = processListLayer.convert(CGRect(x: table.minX, y: table.maxY - CGFloat(index + 1) * rowHeight + processScroll,
                    width: table.width, height: rowHeight), to: rootLayer)
                guard rect.intersects(viewport) else { continue }
                let process = processes[sourceIndex]
                rows.append(accessibilityNode("process/\(process.pid)/\(process.command)", role: .row, frame: rect,
                    label: process.name, value: "PID \(process.pid), \(process.command)", enabled: !isRecording,
                    actions: [.press, .focus], selected: selectedPID == process.pid, focused: selectedPID == process.pid && !processSearchFocused && !perfPathInputController.isFocused, rowIndex: index) { owner, _, _ in
                        owner.blurProcessSearch(); owner.blurPerfPath(commit: true)
                        owner.selectedPID = process.pid
                        owner.statusLayer.string = "Next recording target: \(process.name) (\(process.pid))."
                        owner.updateColors()
                    })
            }
            children.append(accessibilityNode("processes", role: .table, frame: viewport, label: "Processes", children: rows,
                actions: [.scrollUp, .scrollDown], rowCount: filteredProcessIndices.count) { owner, action, _ in
                    owner.processScroll += (action == .scrollDown ? 1 : -1) * owner.processViewportLayer.bounds.height * 0.8
                    owner.clampProcessScroll(); owner.updateProcessScrollPosition()
                })
            children.append(accessibilityNode("perf-path", role: .textField, frame: processListLayer.convert(perfPathFrame, to: rootLayer),
                label: "Path to perf executable", value: perfPathInputController.text, enabled: !isBusy && !isRecording,
                actions: [.focus, .setValue], focused: perfPathInputController.isFocused) { owner, action, value in
                    owner.focusPerfPath(cursorPosition: owner.perfPathInputController.text.count, modifySelection: false)
                    if action == .setValue { owner.perfPathInputController.setText(value); owner.commitPerfPathInput() }
                })
            children.append(accessibilityNode("perf-select", role: .button, frame: processListLayer.convert(perfSelectFrame, to: rootLayer),
                label: "Choose perf executable", enabled: !isBusy && !isRecording, actions: [.press]) { owner, _, _ in owner.openPerfFilePicker() })
        } else if let profile = lastProfile {
            let range = selectedRange ?? 0...Double(profile.duration)
            let summary = "\(profile.totalSampleCount) samples, \(profile.cpuMilliseconds) milliseconds CPU, duration \(profile.duration) seconds. Selected \(range.lowerBound) to \(range.upperBound) seconds."
            var rangeNodes: [OuterframeAccessibilityNode] = []
            for isStart in [true, false] {
                rangeNodes.append(accessibilityNode(isStart ? "range-start" : "range-end", role: .slider, frame: frame(timelineLayer),
                    label: isStart ? "Selection start in seconds" : "Selection end in seconds", value: String(isStart ? range.lowerBound : range.upperBound),
                    hint: "Adjust the selected recording range", actions: [.setValue, .increment, .decrement],
                    minimum: isStart ? 0 : range.lowerBound, maximum: isStart ? range.upperBound : Double(profile.duration)) { owner, action, value in
                        let current = owner.selectedRange ?? 0...Double(profile.duration)
                        let number: Double
                        if action == .setValue {
                            guard let parsed = Double(value), parsed.isFinite else { return }
                            number = parsed
                        } else {
                            let step = max(Double(profile.duration) / 100, 0.001)
                            let proposed = (isStart ? current.lowerBound : current.upperBound) + (action == .increment ? step : -step)
                            number = min(max(proposed, isStart ? 0 : current.lowerBound), isStart ? current.upperBound : Double(profile.duration))
                        }
                        guard number >= 0, number <= Double(profile.duration) else { return }
                        guard isStart ? number <= current.upperBound : number >= current.lowerBound else { return }
                        owner.selectedRange = isStart ? number...current.upperBound : current.lowerBound...number
                        owner.updateTimeline(); owner.fetchSelectedRange()
                    })
            }
            children.append(accessibilityNode("timeline", role: .container, frame: frame(timelineLayer), label: "CPU usage timeline", value: summary, children: rangeNodes))
            let viewport = frame(flameViewportLayer)
            var itemIndex = 0
            func stackRows(at depth: Int) -> [OuterframeAccessibilityNode] {
                var rows: [OuterframeAccessibilityNode] = []
                while itemIndex < flameLayerItems.count, flameLayerItems[itemIndex].depth == depth {
                    let item = flameLayerItems[itemIndex]
                    itemIndex += 1
                    let descendants = stackRows(at: depth + 1)
                    let rect = frame(item.boxLayer).intersection(viewport)
                    guard !rect.isNull || !descendants.isEmpty else { continue }
                    rows.append(accessibilityNode("flame/\(profile.profileID)/\(item.depth)/\(item.xFraction)/\(item.node.frame)", role: .row,
                        frame: rect.isNull ? .zero : rect, label: item.node.frame.symbol,
                        value: "\(item.node.frame.binary), \(item.node.count) samples, \(String(format: "%.1f", 100 * Double(item.node.count) / Double(max(flameTotalSamples, 1)))) percent",
                        children: descendants, disclosureLevel: depth, expanded: descendants.isEmpty ? nil : true))
                }
                return rows
            }
            let boxes = stackRows(at: 0)
            children.append(accessibilityNode("flame", role: .outline, frame: viewport, label: "Call stacks", value: "\(flameTotalSamples) samples. Stack depth identifies caller and callee levels.",
                children: boxes, actions: [.scrollUp, .scrollDown]) { owner, action, _ in
                    owner.flameVerticalScroll += (action == .scrollDown ? 1 : -1) * owner.flameViewportLayer.bounds.height * 0.8
                    owner.clampFlameScroll(); owner.updateFlameScrollPosition()
                })
        }
        return OuterframeAccessibilitySnapshot(rootNodes: [accessibilityNode("root", role: .container, frame: rootLayer.bounds, label: "Profile", children: children)])
    }

    private func updateColors() {
        defer { notifyAccessibilityChanged() }
        appearance.performAsCurrentDrawingAppearance {
            rootLayer.backgroundColor = pageBackgroundColor.cgColor
            toolbarLayer.backgroundColor = toolbarColor.cgColor
            sidebarLayer.backgroundColor = sidebarBackgroundColor.cgColor
            processListLayer.backgroundColor = pageBackgroundColor.cgColor
            processSearchLayer.backgroundColor = searchFieldBackgroundColor.cgColor
            processSearchLayer.borderColor = (processSearchFocused ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor).cgColor
            processSearchLayer.borderWidth = processSearchFocused ? 1.5 : 1
            processSearchPlaceholderLayer.foregroundColor = NSColor.placeholderTextColor.cgColor
            processSearchTextLayer.foregroundColor = NSColor.labelColor.cgColor
            processSearchSelectionLayer.backgroundColor = NSColor.selectedTextBackgroundColor.withAlphaComponent(isDarkMode ? 0.58 : 0.42).cgColor
            processSearchCursorLayer.backgroundColor = NSColor.labelColor.cgColor
            updateSymbolLayer(processSearchIconLayer, symbolName: "magnifyingglass", color: NSColor.secondaryLabelColor)
            filePickerScrollbarController?.updateAppearance(appearance)
            timelineLayer.backgroundColor = pageBackgroundColor.cgColor
            flameLayer.backgroundColor = pageBackgroundColor.cgColor
            statusLayer.foregroundColor = NSColor.secondaryLabelColor.cgColor
            tooltipLayer.backgroundColor = tooltipBackgroundColor.cgColor
            tooltipLayer.borderColor = NSColor.separatorColor.cgColor
            tooltipTextLayer.foregroundColor = NSColor.labelColor.cgColor
            renderFilePicker()
            renderMachineUnsupportedOverlay()
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
        defer { notifyAccessibilityChanged() }
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
        filePickerOverlayLayer.frame = rootLayer.bounds
        machineUnsupportedOverlayLayer.frame = rootLayer.bounds
        timelineLayer.frame = CGRect(x: contentX,
                                     y: max(contentHeight - timelineHeight, 0),
                                     width: contentWidth,
                                     height: min(timelineHeight, contentHeight))
        flameLayer.frame = CGRect(x: contentX, y: 0, width: contentWidth, height: max(contentHeight - timelineLayer.frame.height, 1))

        recordToggleButtonLayer.frame = CGRect(x: sidebarWidth - 50, y: height - toolbarHeight + 11, width: 34, height: 30)
        let refreshButtonWidth: CGFloat = 84
        let statusGap: CGFloat = 18
        refreshButtonLayer.frame = CGRect(x: horizontalInset, y: 11, width: refreshButtonWidth, height: 30)
        refreshButtonLayer.isHidden = !showingSetup
        let statusX = showingSetup ? contentX + refreshButtonLayer.frame.maxX + statusGap : contentX + horizontalInset
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
        renderMachineUnsupportedOverlay()
    }

    private func handleMouseDown(at point: CGPoint, clickCount: Int) {
        if pendingFilePicker != nil {
            handleFilePickerMouseDown(at: point, clickCount: clickCount)
            return
        }

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
        if perfSelectFrame.contains(listPoint), !isBusy, !isRecording {
            blurPerfPath(commit: true)
            openPerfFilePicker()
            return
        }
        if perfPathFrame.contains(listPoint) {
            focusPerfPath(cursorPosition: perfPathCursorPosition(at: listPoint), modifySelection: false)
            return
        }
        if processSearchFrame().contains(listPoint) {
            blurPerfPath(commit: true)
            focusProcessSearch(cursorPosition: processSearchCursorPosition(at: listPoint), modifySelection: false)
            return
        }
        if processListLayer.bounds.contains(listPoint), !processSearchFrame().contains(listPoint) {
            blurProcessSearch()
            blurPerfPath(commit: true)
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
            updateTraceURL(nil)
            profileRequestID = UUID()
            showingSetup = true
            selectedTraceID = nil
            lastProfile = nil
            selectedRange = nil
            statusLayer.string = "Choose a process for the next recording."
            updateColors()
            fetchProcesses()
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
                blurPerfPath(commit: true)
                focusProcessSearch(cursorPosition: processSearchCursorPosition(at: listPoint), modifySelection: false)
                showProcessSearchContextMenu(at: point)
                return
            }
            if perfPathFrame.contains(listPoint) {
                focusPerfPath(cursorPosition: perfPathCursorPosition(at: listPoint), modifySelection: false)
                showPerfPathContextMenu(at: point)
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
        if perfPathContextMenuIDs.remove(menuID) != nil {
            handlePerfPathContextMenuSelection(itemID: itemID)
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

    private func updateTraceURL(_ id: UInt64?) {
        guard let current = currentTraceURL,
              var components = URLComponents(url: current, resolvingAgainstBaseURL: false) else { return }
        let parts = components.path.split(separator: "/")
        let prefix = parts.count >= 2 && parts[0] == "targets" ? "/targets/\(parts[1])" : ""
        components.path = prefix + (id.map { "/traces/\($0)" } ?? "/")
        components.fragment = nil
        guard let url = components.url, url != current else { return }
        currentTraceURL = url
        outerframeHost.pushHistoryEntry(url: url)
    }

    private func restoreTraceURL(_ url: URL?) {
        profileRequestID = UUID()
        var parts = (url?.path ?? "").split(separator: "/")
        if parts.count >= 2 && parts[0] == "targets" { parts.removeFirst(2) }
        let id = parts.count == 2 && parts[0] == "traces" ? UInt64(parts[1]) : nil
        selectedTraceID = id.flatMap { $0 > 0 ? $0 : nil }
        showingSetup = selectedTraceID == nil
        lastProfile = nil
        selectedRange = nil
        resetFlameViewport()
        if let selectedTraceID {
            loadProfile(id: selectedTraceID)
        } else {
            statusLayer.string = "Choose a process for the next recording."
        }
        updateColors()
    }

    private func selectTrace(at index: Int) {
        guard traces.indices.contains(index) else { return }
        blurProcessSearch()
        showingSetup = false
        selectedTraceID = traces[index].profileID
        updateTraceURL(selectedTraceID)
        lastProfile = nil
        selectedRange = nil
        resetFlameViewport()
        loadProfile(id: traces[index].profileID)
        updateColors()
    }

    private func handleMouseDragged(at point: CGPoint) {
        if pendingFilePicker != nil,
           filePickerScrollbarController?.handleMouseDragged(to: rootLayer.convert(point, to: filePickerListLayer)) == true {
            return
        }
        guard rangeDragStart != nil, lastProfile != nil, !showingSetup else { return }
        let timelinePoint = timelineLayer.convert(point, from: rootLayer)
        guard let time = timeForTimelinePoint(timelinePoint) else { return }
        setDraggingRange(end: time)
    }

    private func handleMouseUp(at point: CGPoint) {
        if pendingFilePicker != nil {
            _ = filePickerScrollbarController?.handleMouseUp(at: rootLayer.convert(point, to: filePickerListLayer))
        }
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
        updateCursor(at: point)
        guard !showingSetup else {
            hideTooltip()
            return
        }
        if timelineLayer.frame.contains(point) {
            let timelinePoint = timelineLayer.convert(point, from: rootLayer)
            if showTimelineTooltip(at: timelinePoint, rootPoint: point) {
                return
            }
        }
        guard flameLayer.frame.contains(point) else {
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

    private func updateCursor(at point: CGPoint) {
        if pendingFilePicker != nil {
            if filePickerCancelFrame.contains(point) ||
                FilePickerBreadcrumbBar.hitPath(at: point,
                                                breadcrumbFrame: filePickerBreadcrumbFrame,
                                                segmentFrames: filePickerBreadcrumbSegmentFrames) != nil ||
                (filePickerListFrame.contains(point) &&
                 filePickerEntryFrames.contains(where: { $0.frame.contains(point) })) {
                setCursorIfNeeded(.pointingHand)
            } else {
                setCursorIfNeeded(.arrow)
            }
            return
        }

        if showingSetup, processListLayer.frame.contains(point) {
            let listPoint = processListLayer.convert(point, from: rootLayer)
            if perfPathFrame.contains(listPoint) || processSearchFrame().contains(listPoint) {
                setCursorIfNeeded(.iBeam)
                return
            }
            if perfSelectFrame.contains(listPoint) {
                setCursorIfNeeded(.pointingHand)
                return
            }
        }

        setCursorIfNeeded(.arrow)
    }

    private func setCursorIfNeeded(_ cursor: PluginCursorType) {
        guard currentCursor != cursor else { return }
        currentCursor = cursor
        outerframeHost.setCursor(cursor)
    }

    private func handleKeyDown(keyCode: UInt16,
                               characters: String,
                               charactersIgnoringModifiers: String,
                               modifierFlags: NSEvent.ModifierFlags,
                               isARepeat: Bool) {
        _ = charactersIgnoringModifiers
        _ = isARepeat
        if pendingFilePicker != nil,
           !processSearchFocused,
           !perfPathInputController.isFocused {
            handleFilePickerKeyDown(keyCode: keyCode,
                                    characters: characters,
                                    modifierFlags: modifierFlags)
            return
        }
        guard processSearchFocused || perfPathInputController.isFocused else { return }
        if modifierFlags.contains(.command) {
            switch charactersIgnoringModifiers.lowercased() {
            case "a":
                if processSearchFocused {
                    selectAllProcessSearchText()
                } else {
                    perfPathInputController.selectAll()
                }
            case "c":
                writeFocusedSelectionToPasteboard(cut: false)
            case "x":
                writeFocusedSelectionToPasteboard(cut: true)
            case "v":
                readPasteboardIntoFocusedField()
            default:
                break
            }
            return
        }
        if keyCode == 53 {
            if processSearchFocused {
                if processSearchText.isEmpty {
                    blurProcessSearch()
                } else {
                    setProcessSearchText("")
                }
            } else {
                blurPerfPath(commit: true)
            }
        }
    }

    private func handleFilePickerKeyDown(keyCode: UInt16,
                                         characters: String,
                                         modifierFlags: NSEvent.ModifierFlags) {
        if modifierFlags.contains(.command) || modifierFlags.contains(.control) || modifierFlags.contains(.option) {
            return
        }
        switch keyCode {
        case 126:
            moveFilePickerSelection(delta: -1)
        case 125:
            moveFilePickerSelection(delta: 1)
        case 36, 76:
            activateSelectedFilePickerEntry()
        case 53:
            pendingFilePicker = nil
            resetFilePickerTypeahead()
            renderFilePicker()
        default:
            if let text = filePickerTypeaheadText(from: characters) {
                handleFilePickerTypeahead(text)
            }
        }
    }

    private func filePickerTypeaheadText(from characters: String) -> String? {
        guard !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0) &&
                  !CharacterSet.newlines.contains($0)
              }) else {
            return nil
        }
        return characters
    }

    private func handleTextInput(_ text: String,
                                 hasReplacementRange: Bool,
                                 replacementLocation: UInt64,
                                 replacementLength: UInt64) {
        if perfPathInputController.isFocused {
            guard !text.isEmpty else { return }
            if hasReplacementRange {
                let location = min(Int(replacementLocation), perfPathInputController.text.count)
                let length = min(Int(replacementLength), perfPathInputController.text.count - location)
                perfPathInputController.setCursorPosition(location, modifySelection: false)
                if length > 0 {
                    perfPathInputController.setCursorPosition(location + length, modifySelection: true)
                }
            }
            perfPathInputController.insertText(text)
            return
        }
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

    private func handleSetMarkedText(_ text: String,
                                     selectedLocation: Int,
                                     selectedLength: Int,
                                     hasReplacementRange: Bool,
                                     replacementLocation: Int,
                                     replacementLength: Int) {
        if perfPathInputController.isFocused {
            perfPathInputController.setMarkedText(text,
                                                  selectedLocation: selectedLocation,
                                                  selectedLength: selectedLength,
                                                  replacementRange: perfPathReplacementRange(hasReplacementRange: hasReplacementRange,
                                                                                            location: replacementLocation,
                                                                                            length: replacementLength))
            return
        }
        guard processSearchFocused else { return }
        setMarkedProcessSearchText(text,
                                   selectedLocation: selectedLocation,
                                   selectedLength: selectedLength,
                                   replacementRange: processSearchReplacementRange(hasReplacementRange: hasReplacementRange,
                                                                                   location: replacementLocation,
                                                                                   length: replacementLength))
    }

    private func handleUnmarkText() {
        if perfPathInputController.isFocused {
            perfPathInputController.unmarkText()
            return
        }
        guard processSearchFocused else { return }
        processSearchPendingMarkedRange = processSearchMarkedRange
        processSearchMarkedRange = nil
        updateProcessSearchDisplay()
    }

    private func perfPathReplacementRange(hasReplacementRange: Bool, location: Int, length: Int) -> Range<Int>? {
        guard hasReplacementRange else { return nil }
        let start = min(max(location, 0), perfPathInputController.text.count)
        let end = min(max(start + length, start), perfPathInputController.text.count)
        return start..<end
    }

    private func processSearchReplacementRange(hasReplacementRange: Bool, location: Int, length: Int) -> Range<Int>? {
        guard hasReplacementRange else { return nil }
        let start = min(max(location, 0), processSearchText.count)
        let end = min(max(start + length, start), processSearchText.count)
        return start..<end
    }

    private func handleTextCommand(_ command: String) {
        if perfPathInputController.isFocused {
            let normalized = command.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            if normalized == "cancelOperation" {
                blurPerfPath(commit: true)
            } else {
                perfPathInputController.performCommand(normalized)
            }
            return
        }
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
        if fieldID == Self.perfPathFieldID {
            if hasFocus {
                focusPerfPath(cursorPosition: perfPathInputController.cursorPosition, modifySelection: false)
            } else {
                blurPerfPath(commit: true)
            }
            return
        }
        guard fieldID == Self.processSearchFieldID else { return }
        if hasFocus {
            focusProcessSearch(cursorPosition: processSearchCursorPosition, modifySelection: false)
        } else {
            blurProcessSearch()
        }
    }

    private func handleSetCursorPosition(fieldID: UUID, position: UInt64, modifySelection: Bool) {
        if fieldID == Self.perfPathFieldID {
            focusPerfPath(cursorPosition: min(Int(position), perfPathInputController.text.count), modifySelection: modifySelection)
            return
        }
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
        let newZoom = max(oldZoom * (1 + magnification), 1)
        guard newZoom.isFinite, (viewport.width * newZoom).isFinite,
              abs(newZoom - oldZoom) > 0.001 else { return }

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

    private func showTooltip(text: String, at point: CGPoint) {
        tooltipTextLayer.string = text

        let maxWidth = min(max(rootLayer.bounds.width * 0.5, 260), 560)
        let lines = text.components(separatedBy: "\n")
        let longest = lines.map { CGFloat($0.count) }.max() ?? 1
        let width = min(max(longest * 6.4 + 22, 220), maxWidth)
        let height = CGFloat(lines.count) * 17 + 18
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

    private func showTooltip(for hit: FlameHitRegion, at point: CGPoint) {
        guard hit.total > 0 else {
            hideTooltip()
            return
        }
        let percent = Double(hit.count) * 100.0 / Double(hit.total)
        let binary = hit.binary.isEmpty ? "Unknown binary" : hit.binary
        let text = "\(hit.symbol)\nBinary: \(binary)\nSamples: \(hit.count) of \(hit.total) (\(String(format: "%.1f", percent))%)\nStack depth: \(hit.depth + 1)"
        showTooltip(text: text, at: point)
    }

    private func hideTooltip() {
        guard !tooltipLayer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tooltipLayer.isHidden = true
        CATransaction.commit()
    }

    private func fetchProfiles() {
        guard let endpoint = profileListEndpoint, let urlSession else { return }
        urlSession.dataTask(with: endpoint) { [weak self] data, _, error in
            let result = data.flatMap(ProfileBinary.decodeProfileList)
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.traces = result.profiles
                    self.isRecording = result.recording
                    self.activeRecordingID = result.recording ? result.recordingID : nil
                    self.updateColors()
                } else {
                    self.statusLayer.string = error?.localizedDescription ?? "Could not load recordings."
                }
            }
        }.resume()
    }

    private func fetchProcesses() {
        guard let endpoint = processesEndpoint, let urlSession else { return }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "containers", value: "1")]
        guard let url = components?.url else { return }
        statusLayer.string = "Loading processes..."
        urlSession.dataTask(with: url) { [weak self] data, _, error in
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
                    if self.showingSetup {
                        self.statusLayer.string = self.setupStatusText()
                    }
                    self.updateColors()
                } else {
                    if self.showingSetup {
                        self.statusLayer.string = error?.localizedDescription ?? "Could not load processes."
                    }
                }
            }
        }.resume()
    }

    private func setupStatusText() -> String {
        if let selectedPID,
           let process = processes.first(where: { $0.pid == selectedPID }) {
            return "Next recording target: \(process.name) (\(process.pid))."
        }
        return nextRecordingStatusText()
    }

    private func nextRecordingStatusText() -> String {
        let message = perfMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if !perfUsable && !message.isEmpty {
            return message
        }
        return "Choose a process for the next recording."
    }

    private func fetchPerfConfig() {
        guard let endpoint = perfEndpoint, let urlSession else { return }
        urlSession.dataTask(with: endpoint) { [weak self] data, _, _ in
            let result = data.flatMap(ProfileBinary.decodePerfConfig)
            Task { @MainActor in
                guard let self, let result else { return }
                self.perfPath = result.path
                self.perfUsable = result.usable
                self.perfMessage = result.message
                self.perfMachineUnsupported = result.machineUnsupported
                if !self.perfPathInputController.isFocused {
                    self.perfPathInputController.setText(result.path)
                }
                if self.showingSetup, self.selectedPID == nil {
                    self.statusLayer.string = self.nextRecordingStatusText()
                }
                self.updateLayout()
            }
        }.resume()
    }

    private func setPerfPath(_ path: String) {
        guard let endpoint = perfEndpoint, let urlSession else { return }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components?.url else { return }
        statusLayer.string = "Checking perf..."
        urlSession.dataTask(with: url) { [weak self] data, _, error in
            let result = data.flatMap(ProfileBinary.decodePerfConfig)
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.perfPath = result.path
                    self.perfUsable = result.usable
                    self.perfMessage = result.message
                    self.perfMachineUnsupported = result.machineUnsupported
                    if !self.perfPathInputController.isFocused {
                        self.perfPathInputController.setText(result.path)
                    }
                    self.statusLayer.string = result.usable ? "Using \(result.path)." : result.message
                } else {
                    self.statusLayer.string = error?.localizedDescription ?? "Could not set perf path."
                }
                self.updateColors()
            }
        }.resume()
    }

    private func openPerfFilePicker() {
        blurProcessSearch()
        let sourcePath = perfPathInputController.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialPath: String
        if sourcePath.hasPrefix("/") {
            let parent = (sourcePath as NSString).deletingLastPathComponent
            initialPath = parent.isEmpty ? "/" : parent
        } else {
            initialPath = "/"
        }
        blurPerfPath(commit: false)
        pendingFilePicker = FilePickerResponse(path: initialPath, parent: "/", entries: [])
        filePickerScroll = 0
        filePickerSelectedIndex = nil
        resetFilePickerTypeahead()
        fetchFilePicker(path: initialPath)
        renderFilePicker()
    }

    private func fetchFilePicker(path: String) {
        guard let endpoint = filePickerEndpoint, let urlSession else { return }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components?.url else { return }
        urlSession.dataTask(with: url) { [weak self] data, _, error in
            let result = data.flatMap(ProfileBinary.decodeFilePicker)
            Task { @MainActor in
                guard let self, self.pendingFilePicker != nil else { return }
                if let result {
                    self.pendingFilePicker = result
                    self.filePickerScroll = 0
                    self.filePickerSelectedIndex = nil
                    self.resetFilePickerTypeahead()
                } else {
                    self.statusLayer.string = error?.localizedDescription ?? "Could not load directory."
                }
                self.renderFilePicker()
            }
        }.resume()
    }

    private func startRecording() {
        guard !isRecording, perfUsable, !perfMachineUnsupported, let selectedPID, let profileStartEndpoint, let urlSession else { return }
        guard let process = processes.first(where: { $0.pid == selectedPID }) else { return }
        commitPerfPathInput()
        var components = URLComponents(url: profileStartEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "pid", value: String(selectedPID)),
            URLQueryItem(name: "container", value: process.containerID),
            URLQueryItem(name: "startTime", value: String(process.startTime)),
            URLQueryItem(name: "frequency", value: "1000"),
            URLQueryItem(name: "perfPath", value: perfPathInputController.text.trimmingCharacters(in: .whitespacesAndNewlines))
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
                    self.updateTraceURL(decoded.profileID)
                    self.showingSetup = false
                    self.selectedRange = decoded.rangeStart...decoded.rangeEnd
                    self.resetFlameViewport()
                    self.statusLayer.string = self.summaryText(for: decoded)
                    self.fetchProfiles()
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
        let requestID = UUID()
        profileRequestID = requestID
        isFetchingRange = true
        statusLayer.string = "Loading recording..."
        urlSession.dataTask(with: url) { [weak self] data, response, error in
            let decoded = data.flatMap(ProfileBinary.decodeProfile)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Task { @MainActor in
                guard let self, self.profileRequestID == requestID, !self.showingSetup else { return }
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
                    self.updateTraceURL(self.showingSetup ? nil : self.selectedTraceID)
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
        let requestID = UUID()
        profileRequestID = requestID
        isFetchingRange = true
        statusLayer.string = "Filtering \(formatDuration(selectedRange.upperBound - selectedRange.lowerBound))..."
        urlSession.dataTask(with: url) { [weak self] data, response, error in
            let decoded = data.flatMap(ProfileBinary.decodeProfile)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            Task { @MainActor in
                guard let self, self.profileRequestID == requestID, !self.showingSetup else { return }
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
        defer { notifyAccessibilityChanged() }
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
            renderPerfPathRow()
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
        let search = processSearchFrame()
        let tableY: CGFloat = 92
        let tableTop = search.minY - 12
        return CGRect(x: 18,
                      y: tableY,
                      width: max(processListLayer.bounds.width - 36, 1),
                      height: max(tableTop - tableY, 1))
    }

    private func renderPerfPathRow() {
        let y: CGFloat = 22
        let label = makeTextLayer(size: 11, weight: .medium)
        label.string = "Path to perf executable"
        label.foregroundColor = resolvedCGColor(NSColor.secondaryLabelColor)
        label.frame = CGRect(x: 24, y: y + 34, width: max(processListLayer.bounds.width - 48, 1), height: 14)
        processChromeLayer.addSublayer(label)

        let buttonWidth: CGFloat = 72
        perfSelectFrame = CGRect(x: max(processListLayer.bounds.width - 24 - buttonWidth, 24),
                                 y: y,
                                 width: buttonWidth,
                                 height: 30)
        perfPathFrame = CGRect(x: 24,
                               y: y,
                               width: max(perfSelectFrame.minX - 32, 80),
                               height: 30)

        let pathField = CALayer()
        pathField.frame = perfPathFrame
        pathField.cornerRadius = 6
        pathField.masksToBounds = true
        pathField.actions = noImplicitLayerActions()
        pathField.borderWidth = 1
        pathField.borderColor = resolvedCGColor(perfPathInputController.isFocused
                                                ? NSColor.keyboardFocusIndicatorColor
                                                : (perfUsable ? NSColor.separatorColor : NSColor.systemRed.withAlphaComponent(0.55)))
        pathField.backgroundColor = resolvedCGColor(searchFieldBackgroundColor)
        processChromeLayer.addSublayer(pathField)

        let textFrame = perfPathTextFrame(fieldBounds: pathField.bounds)
        let displayText = perfPathInputController.isFocused ? perfPathInputController.text : perfPath
        if perfPathInputController.isFocused,
           let range = perfPathInputController.selectionRange {
            let line = makePerfPathLine(text: displayText)
            let lower = offsetForCharacter(line: line,
                                           index: range.lowerBound,
                                           in: displayText,
                                           maxWidth: textFrame.width)
            let upper = offsetForCharacter(line: line,
                                           index: range.upperBound,
                                           in: displayText,
                                           maxWidth: textFrame.width)
            let selection = CALayer()
            selection.actions = noImplicitLayerActions()
            selection.frame = CGRect(x: textFrame.minX + min(lower, upper),
                                     y: textFrame.minY + 1,
                                     width: max(abs(upper - lower), 1),
                                     height: textFrame.height - 2)
            selection.cornerRadius = 2
            selection.backgroundColor = resolvedCGColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(isDarkMode ? 0.58 : 0.42))
            pathField.addSublayer(selection)
        }

        let pathText = makeTextLayer(size: 12, weight: .regular)
        pathText.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        pathText.actions = noImplicitLayerActions()
        pathText.foregroundColor = resolvedCGColor(perfUsable ? NSColor.labelColor : NSColor.systemRed)
        pathText.string = displayText
        pathText.frame = textFrame
        pathField.addSublayer(pathText)

        if perfPathInputController.isFocused, perfPathInputController.selectionRange == nil {
            let line = makePerfPathLine(text: displayText)
            let offset = offsetForCharacter(line: line,
                                            index: perfPathInputController.cursorPosition,
                                            in: displayText,
                                            maxWidth: textFrame.width)
            let caret = CALayer()
            caret.actions = noImplicitLayerActions()
            caret.frame = CGRect(x: textFrame.minX + offset,
                                 y: textFrame.minY + 1,
                                 width: 1,
                                 height: textFrame.height - 2)
            caret.backgroundColor = resolvedCGColor(NSColor.labelColor)
            pathField.addSublayer(caret)
        }

        let select = makeButtonLayer(title: "Select")
        select.frame = perfSelectFrame
        select.sublayers?.first?.frame = select.bounds.insetBy(dx: 10, dy: 6)
        processChromeLayer.addSublayer(select)

        if !perfMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let message = makeTextLayer(size: 11, weight: .regular)
            message.string = perfUsable ? "perf is usable" : perfMessage.trimmingCharacters(in: .whitespacesAndNewlines)
            message.foregroundColor = resolvedCGColor(perfUsable ? NSColor.secondaryLabelColor : NSColor.systemRed)
            message.frame = CGRect(x: 24, y: y - 18, width: max(processListLayer.bounds.width - 48, 1), height: 14)
            processChromeLayer.addSublayer(message)
        }
    }

    private func renderMachineUnsupportedOverlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        machineUnsupportedOverlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        machineUnsupportedTextLines.removeAll()
        machineUnsupportedOverlayLayer.frame = rootLayer.bounds
        guard perfMachineUnsupported else {
            machineUnsupportedOverlayLayer.isHidden = true
            machineUnsupportedPanelFrame = .zero
            CATransaction.commit()
            return
        }

        machineUnsupportedOverlayLayer.isHidden = false
        machineUnsupportedOverlayLayer.backgroundColor = resolvedCGColor(NSColor.black.withAlphaComponent(isDarkMode ? 0.42 : 0.24))

        let panelWidth = min(max(rootLayer.bounds.width * 0.58, 420), 680)
        let panelHeight: CGFloat = 198
        let panel = CALayer()
        machineUnsupportedPanelFrame = CGRect(x: floor((rootLayer.bounds.width - panelWidth) / 2),
                                              y: floor((rootLayer.bounds.height - panelHeight) / 2),
                                              width: panelWidth,
                                              height: panelHeight)
        panel.frame = machineUnsupportedPanelFrame
        panel.cornerRadius = 12
        panel.borderWidth = 1
        panel.borderColor = resolvedCGColor(NSColor.systemRed.withAlphaComponent(isDarkMode ? 0.55 : 0.42))
        panel.backgroundColor = resolvedCGColor(NSColor.windowBackgroundColor)
        panel.shadowColor = NSColor.black.cgColor
        panel.shadowOpacity = isDarkMode ? 0.36 : 0.18
        panel.shadowRadius = 24
        panel.shadowOffset = CGSize(width: 0, height: -8)
        machineUnsupportedOverlayLayer.addSublayer(panel)

        let icon = makeSymbolLayer("exclamationmark.triangle.fill", color: NSColor.systemRed, renderSize: 64)
        icon.frame = CGRect(x: 24, y: panelHeight - 62, width: 32, height: 32)
        panel.addSublayer(icon)

        let title = makeTextLayer(size: 18, weight: .semibold)
        title.string = "Profile cannot be used on this machine"
        title.foregroundColor = resolvedCGColor(NSColor.labelColor)
        title.frame = CGRect(x: 68, y: panelHeight - 56, width: max(panelWidth - 92, 1), height: 24)
        panel.addSublayer(title)

        let bodyFrame = CGRect(x: 24, y: 28, width: max(panelWidth - 48, 1), height: panelHeight - 104)
        renderMachineUnsupportedSelectableText(machineUnsupportedBodyText(), in: bodyFrame, on: panel)

        CATransaction.commit()
    }

    private func renderMachineUnsupportedSelectableText(_ text: String, in frame: CGRect, on panel: CALayer) {
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let lines = wrappedMachineUnsupportedTextLines(text, font: font, frame: frame)
        machineUnsupportedTextLines = lines
        if let range = machineUnsupportedSelectionRange() {
            for line in lines {
                guard let intersection = intersectRanges(range, line.range),
                      intersection.lowerBound < intersection.upperBound else { continue }
                let highlight = CALayer()
                highlight.actions = noImplicitLayerActions()
                highlight.frame = selectionRect(for: intersection, in: line)
                highlight.cornerRadius = 2
                highlight.backgroundColor = resolvedCGColor(NSColor.selectedTextBackgroundColor.withAlphaComponent(isDarkMode ? 0.62 : 0.44))
                panel.addSublayer(highlight)
            }
        }
        for line in lines {
            let layer = makeTextLayer(size: 13, weight: .regular)
            layer.string = line.text
            layer.foregroundColor = resolvedCGColor(NSColor.secondaryLabelColor)
            layer.frame = line.frame
            panel.addSublayer(layer)
        }
    }

    private func wrappedMachineUnsupportedTextLines(_ text: String,
                                                    font: NSFont,
                                                    frame: CGRect) -> [MachineUnsupportedTextLine] {
        guard !text.isEmpty else { return [] }
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let nsText = text as NSString
        let lineHeight: CGFloat = 17
        let maxLines = max(Int(floor(frame.height / lineHeight)), 1)
        var utf16Start = 0
        var result: [MachineUnsupportedTextLine] = []
        while utf16Start < nsText.length, result.count < maxLines {
            var length = CTTypesetterSuggestLineBreak(typesetter, utf16Start, Double(frame.width))
            if length <= 0 { length = 1 }
            let nsRange = NSRange(location: utf16Start, length: min(length, nsText.length - utf16Start))
            var lineText = nsText.substring(with: nsRange)
            while lineText.hasSuffix("\n") || lineText.hasSuffix("\r") {
                lineText.removeLast()
            }
            let charStart = characterIndex(forUTF16: nsRange.location, in: text)
            let charEnd = characterIndex(forUTF16: nsRange.location + nsRange.length, in: text)
            let y = frame.maxY - CGFloat(result.count + 1) * lineHeight
            result.append(MachineUnsupportedTextLine(text: lineText,
                                                     range: charStart..<charEnd,
                                                     frame: CGRect(x: frame.minX,
                                                                   y: y,
                                                                   width: frame.width,
                                                                   height: lineHeight),
                                                     font: font))
            utf16Start += nsRange.length
        }
        return result
    }

    private func machineUnsupportedSelectionRange() -> Range<Int>? {
        guard let anchor = machineUnsupportedSelectionAnchor,
              let focus = machineUnsupportedSelectionFocus,
              anchor != focus else { return nil }
        return min(anchor, focus)..<max(anchor, focus)
    }

    private func intersectRanges(_ first: Range<Int>, _ second: Range<Int>) -> Range<Int>? {
        let lower = max(first.lowerBound, second.lowerBound)
        let upper = min(first.upperBound, second.upperBound)
        guard lower < upper else { return nil }
        return lower..<upper
    }

    private func selectionRect(for range: Range<Int>, in line: MachineUnsupportedTextLine) -> CGRect {
        let lineObject = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.font: line.font]))
        let lowerIndex = min(max(range.lowerBound - line.range.lowerBound, 0), line.text.count)
        let upperIndex = min(max(range.upperBound - line.range.lowerBound, 0), line.text.count)
        let lower = offsetForCharacter(line: lineObject,
                                       index: lowerIndex,
                                       in: line.text,
                                       maxWidth: line.frame.width)
        let upper = offsetForCharacter(line: lineObject,
                                       index: upperIndex,
                                       in: line.text,
                                       maxWidth: line.frame.width)
        return CGRect(x: line.frame.minX + min(lower, upper),
                      y: line.frame.minY + 1,
                      width: max(abs(upper - lower), 1),
                      height: line.frame.height - 2)
    }

    private func machineUnsupportedBodyText() -> String {
        let message = perfMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty
            ? "This machine does not support the Linux perf events that Profile needs to record stack samples."
            : message
    }

    private func machineUnsupportedCharacterIndex(at point: CGPoint) -> Int? {
        guard perfMachineUnsupported,
              !machineUnsupportedPanelFrame.isEmpty,
              machineUnsupportedPanelFrame.contains(point) else { return nil }
        let localPoint = CGPoint(x: point.x - machineUnsupportedPanelFrame.minX,
                                 y: point.y - machineUnsupportedPanelFrame.minY)
        guard !machineUnsupportedTextLines.isEmpty else { return nil }

        if localPoint.y >= machineUnsupportedTextLines[0].frame.maxY {
            return machineUnsupportedTextLines[0].range.lowerBound
        }
        if localPoint.y <= machineUnsupportedTextLines[machineUnsupportedTextLines.count - 1].frame.minY {
            return machineUnsupportedTextLines[machineUnsupportedTextLines.count - 1].range.upperBound
        }

        let line = machineUnsupportedTextLines.first(where: { $0.frame.insetBy(dx: 0, dy: -2).contains(localPoint) })
        guard let line else { return nil }
        let clampedX = min(max(localPoint.x - line.frame.minX, 0), line.frame.width)
        guard !line.text.isEmpty else { return line.range.lowerBound }
        let lineObject = CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: [.font: line.font]))
        let utf16Index = CTLineGetStringIndexForPosition(lineObject, CGPoint(x: clampedX, y: 0))
        if utf16Index == kCFNotFound {
            return clampedX > line.frame.width * 0.5 ? line.range.upperBound : line.range.lowerBound
        }
        return min(line.range.upperBound,
                   line.range.lowerBound + characterIndex(forUTF16: utf16Index, in: line.text))
    }

    private func handleMachineUnsupportedMouseDown(at point: CGPoint, clickCount: Int) {
        guard let index = machineUnsupportedCharacterIndex(at: point) else {
            clearMachineUnsupportedSelection()
            return
        }
        if clickCount >= 3 {
            let range = machineUnsupportedParagraphRange(containing: index)
            machineUnsupportedSelectionAnchor = range.lowerBound
            machineUnsupportedSelectionFocus = range.upperBound
            isSelectingMachineUnsupportedText = false
        } else if clickCount == 2 {
            let range = machineUnsupportedWordRange(containing: index)
            machineUnsupportedSelectionAnchor = range.lowerBound
            machineUnsupportedSelectionFocus = range.upperBound
            isSelectingMachineUnsupportedText = false
        } else {
            machineUnsupportedSelectionAnchor = index
            machineUnsupportedSelectionFocus = index
            isSelectingMachineUnsupportedText = true
        }
        renderMachineUnsupportedOverlay()
    }

    private func machineUnsupportedWordRange(containing index: Int) -> Range<Int> {
        let text = machineUnsupportedBodyText()
        guard !text.isEmpty else { return 0..<0 }
        let characters = Array(text)
        var location = min(max(index, 0), characters.count - 1)
        if location > 0, !isMachineUnsupportedWordCharacter(characters[location]) {
            location -= 1
        }
        guard isMachineUnsupportedWordCharacter(characters[location]) else {
            let clamped = min(max(index, 0), characters.count)
            return clamped..<clamped
        }

        var start = location
        while start > 0, isMachineUnsupportedWordCharacter(characters[start - 1]) {
            start -= 1
        }
        var end = location + 1
        while end < characters.count, isMachineUnsupportedWordCharacter(characters[end]) {
            end += 1
        }
        return start..<end
    }

    private func machineUnsupportedParagraphRange(containing index: Int) -> Range<Int> {
        let text = machineUnsupportedBodyText()
        guard !text.isEmpty else { return 0..<0 }
        let characters = Array(text)
        var location = min(max(index, 0), characters.count - 1)
        if location > 0, characters[location] == "\n" {
            location -= 1
        }

        var start = location
        while start > 0, characters[start - 1] != "\n" {
            start -= 1
        }
        var end = location
        while end < characters.count, characters[end] != "\n" {
            end += 1
        }
        return start..<end
    }

    private func isMachineUnsupportedWordCharacter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else {
            return false
        }
        if CharacterSet.alphanumerics.contains(scalar) { return true }
        return "_-./~:".unicodeScalars.contains(scalar)
    }

    private func handleMachineUnsupportedMouseDragged(at point: CGPoint) {
        guard isSelectingMachineUnsupportedText else { return }
        machineUnsupportedSelectionFocus = machineUnsupportedCharacterIndex(at: point)
            ?? (point.y < machineUnsupportedPanelFrame.midY ? machineUnsupportedBodyText().count : 0)
        renderMachineUnsupportedOverlay()
    }

    private func handleMachineUnsupportedMouseUp(at point: CGPoint) {
        guard isSelectingMachineUnsupportedText else { return }
        isSelectingMachineUnsupportedText = false
        if let index = machineUnsupportedCharacterIndex(at: point) {
            machineUnsupportedSelectionFocus = index
        }
        renderMachineUnsupportedOverlay()
    }

    private func clearMachineUnsupportedSelection() {
        machineUnsupportedSelectionAnchor = nil
        machineUnsupportedSelectionFocus = nil
        isSelectingMachineUnsupportedText = false
        renderMachineUnsupportedOverlay()
    }

    private func machineUnsupportedSelectedText() -> String? {
        guard let range = machineUnsupportedSelectionRange() else { return nil }
        let text = machineUnsupportedBodyText()
        let lower = min(max(range.lowerBound, 0), text.count)
        let upper = min(max(range.upperBound, lower), text.count)
        let start = text.index(text.startIndex, offsetBy: lower)
        let end = text.index(text.startIndex, offsetBy: upper)
        let selected = String(text[start..<end])
        return selected.isEmpty ? nil : selected
    }

    private func machineUnsupportedPasteboardItems() -> [OuterContentPasteboardItem] {
        textPasteboardItems(machineUnsupportedSelectedText())
    }

    private func writeMachineUnsupportedSelectionToPasteboard() {
        let items = machineUnsupportedPasteboardItems()
        guard !items.isEmpty else { return }
        outerframeHost.requestPasteboardWrite(items: items) { _ in }
    }

    private func handleMachineUnsupportedKeyDown(charactersIgnoringModifiers: String,
                                                 modifierFlags: NSEvent.ModifierFlags) {
        guard modifierFlags.contains(.command) else { return }
        switch charactersIgnoringModifiers.lowercased() {
        case "c":
            writeMachineUnsupportedSelectionToPasteboard()
        case "a":
            machineUnsupportedSelectionAnchor = 0
            machineUnsupportedSelectionFocus = machineUnsupportedBodyText().count
            renderMachineUnsupportedOverlay()
        default:
            break
        }
    }

    private func showMachineUnsupportedContextMenu(at point: CGPoint) {
        if machineUnsupportedCharacterIndex(at: point) == nil, machineUnsupportedSelectedText() == nil {
            return
        }
        let menuID = UUID()
        machineUnsupportedContextMenuIDs.insert(menuID)
        let items = [
            OuterframeContextMenuItem(id: "copy",
                                      title: "Copy",
                                      isEnabled: machineUnsupportedSelectedText() != nil,
                                      keyEquivalent: "c",
                                      keyEquivalentModifierMask: UInt32(truncatingIfNeeded: NSEvent.ModifierFlags.command.rawValue))
        ]
        outerframeHost.showContextMenu(menuID: menuID, items: items, at: point)
    }

    private func handleMachineUnsupportedContextMenuSelection(menuID: UUID, itemID: String) {
        guard machineUnsupportedContextMenuIDs.remove(menuID) != nil else { return }
        if itemID == "copy" {
            writeMachineUnsupportedSelectionToPasteboard()
        }
    }

    private func renderFilePicker() {
        defer { notifyAccessibilityChanged() }
        appearance.performAsCurrentDrawingAppearance {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }

            filePickerOverlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            filePickerEntryFrames.removeAll()
            filePickerBreadcrumbSegmentFrames.removeAll()
            guard let picker = pendingFilePicker else {
                filePickerOverlayLayer.isHidden = true
                filePickerPanelFrame = .zero
                filePickerListFrame = .zero
                filePickerBreadcrumbFrame = .zero
                filePickerCancelFrame = .zero
                filePickerSelectedIndex = nil
                filePickerContentHeight = 0
                resetFilePickerTypeahead()
                resetFilePickerRowLayers()
                updateFilePickerScrollbarLayout()
                return
            }
            clampFilePickerSelection()

            filePickerOverlayLayer.isHidden = false
            filePickerOverlayLayer.frame = rootLayer.bounds
            filePickerOverlayLayer.backgroundColor = resolvedCGColor(NSColor.black.withAlphaComponent(0.18))

            let panelWidth = min(max(rootLayer.bounds.width - 56, 480), 760)
            let panelHeight = min(max(rootLayer.bounds.height - 80, 340), 540)
            let panel = CALayer()
            filePickerPanelFrame = CGRect(x: floor((rootLayer.bounds.width - panelWidth) / 2),
                                          y: floor((rootLayer.bounds.height - panelHeight) / 2),
                                          width: panelWidth,
                                          height: panelHeight)
            panel.frame = filePickerPanelFrame
            panel.cornerRadius = 8
            panel.borderWidth = 1
            panel.backgroundColor = resolvedCGColor(NSColor.windowBackgroundColor)
            panel.borderColor = resolvedCGColor(NSColor.separatorColor)
            filePickerOverlayLayer.addSublayer(panel)

            let title = makeTextLayer(size: 15, weight: .semibold)
            title.string = "Choose perf"
            title.frame = CGRect(x: 18, y: panelHeight - 38, width: panelWidth - 36, height: 20)
            panel.addSublayer(title)

            let breadcrumbFrame = CGRect(x: 18, y: panelHeight - 78, width: panelWidth - 36, height: FilePickerBreadcrumbBar.height)
            filePickerBreadcrumbFrame = breadcrumbFrame.offsetBy(dx: filePickerPanelFrame.minX, dy: filePickerPanelFrame.minY)
            let breadcrumb = CALayer()
            breadcrumb.frame = breadcrumbFrame
            breadcrumb.masksToBounds = true
            FilePickerBreadcrumbBar.render(path: picker.path,
                                           in: breadcrumb,
                                           segmentFrames: &filePickerBreadcrumbSegmentFrames,
                                           appearance: appearance)
            panel.addSublayer(breadcrumb)

            let bottomControlsHeight: CGFloat = 72
            let listFrame = CGRect(x: 18, y: bottomControlsHeight, width: panelWidth - 36, height: max(breadcrumbFrame.minY - bottomControlsHeight - 10, 80))
            filePickerListFrame = listFrame.offsetBy(dx: filePickerPanelFrame.minX, dy: filePickerPanelFrame.minY)
            filePickerListLayer.frame = listFrame
            filePickerListLayer.cornerRadius = 6
            filePickerListLayer.borderWidth = 1
            filePickerListLayer.borderColor = resolvedCGColor(NSColor.separatorColor)
            filePickerListLayer.backgroundColor = resolvedCGColor(tableBackgroundColor)
            filePickerListLayer.masksToBounds = true
            panel.addSublayer(filePickerListLayer)

            if filePickerRowsContentLayer.superlayer !== filePickerListLayer {
                filePickerListLayer.addSublayer(filePickerRowsContentLayer)
            }
            if filePickerStatusLayer.superlayer !== filePickerListLayer {
                filePickerListLayer.addSublayer(filePickerStatusLayer)
            }
            filePickerStatusLayer.frame = filePickerListLayer.bounds
            filePickerStatusLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            updateFilePickerVisibleRows(rebuild: true)

            let cancel = makeButtonLayer(title: "Cancel")
            cancel.frame = CGRect(x: panelWidth - 18 - 72, y: 20, width: 72, height: 30)
            cancel.sublayers?.first?.frame = cancel.bounds.insetBy(dx: 10, dy: 6)
            filePickerCancelFrame = cancel.frame.offsetBy(dx: filePickerPanelFrame.minX, dy: filePickerPanelFrame.minY)
            panel.addSublayer(cancel)
            updateFilePickerScrollbarLayout()
        }
    }

    private func makeFilePickerRowLayer() -> CALayer {
        let row = CALayer()

        let icon = CALayer()
        icon.contentsGravity = .resizeAspect
        icon.contentsScale = 2
        row.addSublayer(icon)

        let name = makeTextLayer(size: 12, weight: .regular)
        row.addSublayer(name)
        return row
    }

    private func configureFilePickerRowLayer(_ row: CALayer,
                                             entry: FilePickerEntry,
                                             index: Int,
                                             frame: CGRect) {
        row.frame = frame
        let isSelected = filePickerSelectedIndex == index
        row.backgroundColor = isSelected ? resolvedCGColor(NSColor.selectedContentBackgroundColor) : nil

        if row.sublayers?.count != 2 {
            row.sublayers?.forEach { $0.removeFromSuperlayer() }
            let icon = CALayer()
            icon.contentsGravity = .resizeAspect
            icon.contentsScale = 2
            row.addSublayer(icon)
            row.addSublayer(makeTextLayer(size: 12, weight: .regular))
        }

        if let icon = row.sublayers?[0] {
            icon.frame = CGRect(x: 18, y: 6, width: 16, height: 16)
            updateSymbolLayer(icon,
                              symbolName: entry.isDirectory ? "folder" : "terminal",
                              color: isSelected ? .white : (entry.isDirectory ? NSColor.controlAccentColor : NSColor.secondaryLabelColor),
                              renderSize: 15)
        }

        if let name = row.sublayers?[1] as? CATextLayer {
            name.string = entry.name
            name.foregroundColor = resolvedCGColor(isSelected ? .white : NSColor.labelColor)
            name.frame = CGRect(x: 48, y: 6, width: max(frame.width - 58, 1), height: 16)
        }
    }

    private func recycleFilePickerRowLayer(_ layer: CALayer) {
        layer.removeFromSuperlayer()
        filePickerReusableRowLayers.append(layer)
    }

    private func resetFilePickerRowLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        filePickerRowsContentLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        filePickerVisibleRowLayers.removeAll()
        filePickerReusableRowLayers.removeAll()
        filePickerEntryFrames.removeAll()
        filePickerRowsContentLayer.frame = CGRect(origin: .zero,
                                                  size: CGSize(width: filePickerListLayer.bounds.width,
                                                               height: 0))
        CATransaction.commit()
    }

    fileprivate func setFilePickerScroll(_ value: CGFloat) {
        let maxPickerScroll = max(filePickerContentHeight - filePickerListFrame.height, 0)
        let clamped = min(max(value, 0), maxPickerScroll)
        guard abs(clamped - filePickerScroll) > 0.001 else {
            updateFilePickerScrollbarLayout()
            return
        }
        filePickerScroll = clamped
        updateFilePickerVisibleRows(rebuild: false)
    }

    private func updateFilePickerVisibleRows(rebuild: Bool) {
        guard pendingFilePicker != nil else {
            resetFilePickerRowLayers()
            return
        }

        let entries = pendingFilePicker?.entries ?? []
        let viewportHeight = max(filePickerListLayer.bounds.height, 0)
        let viewportWidth = max(filePickerListLayer.bounds.width, 1)
        filePickerContentHeight = CGFloat(entries.count) * filePickerRowHeight
        let maxPickerScroll = max(filePickerContentHeight - viewportHeight, 0)
        filePickerScroll = min(max(filePickerScroll, 0), maxPickerScroll)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        filePickerEntryFrames.removeAll()

        let contentY = viewportHeight - filePickerContentHeight + filePickerScroll
        filePickerRowsContentLayer.frame = CGRect(x: 0,
                                                  y: contentY,
                                                  width: viewportWidth,
                                                  height: max(filePickerContentHeight, 0))

        guard !entries.isEmpty, viewportHeight > 0 else {
            filePickerRowsContentLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            filePickerVisibleRowLayers.removeAll()
            filePickerReusableRowLayers.removeAll()
            filePickerEntryFrames.removeAll()
            filePickerRowsContentLayer.frame = CGRect(origin: .zero,
                                                      size: CGSize(width: viewportWidth, height: 0))
            CATransaction.commit()
            updateFilePickerScrollbarLayout()
            return
        }

        let visibleStart = max(Int(floor(filePickerScroll / filePickerRowHeight)), 0)
        let visibleEnd = min(entries.count, visibleStart + Int(ceil(viewportHeight / filePickerRowHeight)) + 2)
        let visibleRange = visibleStart..<visibleEnd

        let staleIndices = filePickerVisibleRowLayers.keys.filter { !visibleRange.contains($0) }
        for index in staleIndices {
            if let layer = filePickerVisibleRowLayers[index] {
                recycleFilePickerRowLayer(layer)
            }
            filePickerVisibleRowLayers.removeValue(forKey: index)
        }

        for index in visibleRange {
            let entry = entries[index]
            let rowFrame = CGRect(x: 0,
                                  y: filePickerContentHeight - CGFloat(index + 1) * filePickerRowHeight,
                                  width: viewportWidth,
                                  height: filePickerRowHeight)
            let row: CALayer
            if let existing = filePickerVisibleRowLayers[index] {
                row = existing
            } else if let reusable = filePickerReusableRowLayers.popLast() {
                row = reusable
                filePickerRowsContentLayer.addSublayer(row)
                filePickerVisibleRowLayers[index] = row
            } else {
                row = makeFilePickerRowLayer()
                filePickerRowsContentLayer.addSublayer(row)
                filePickerVisibleRowLayers[index] = row
            }
            configureFilePickerRowLayer(row, entry: entry, index: index, frame: rowFrame)

            let visibleFrame = rowFrame.offsetBy(dx: filePickerRowsContentLayer.frame.minX,
                                                 dy: filePickerRowsContentLayer.frame.minY)
            filePickerEntryFrames.append((visibleFrame.offsetBy(dx: filePickerListFrame.minX,
                                                                dy: filePickerListFrame.minY),
                                          entry,
                                          index))
        }

        CATransaction.commit()
        updateFilePickerScrollbarLayout()
    }

    private func filePickerScrollbarMetrics() -> ScrollbarController<FilePickerScrollbarDelegate>.Metrics {
        ScrollbarController.Metrics(viewportSize: filePickerListLayer.bounds.size,
                                    contentHeight: filePickerContentHeight,
                                    scrollOffset: filePickerScroll)
    }

    private func updateFilePickerScrollbarLayout() {
        filePickerScrollbarController?.updateLayout(metrics: filePickerScrollbarMetrics())
    }

    private func handleFilePickerMouseDown(at point: CGPoint, clickCount: Int) {
        if filePickerCancelFrame.contains(point) || !filePickerPanelFrame.contains(point) {
            pendingFilePicker = nil
            renderFilePicker()
            return
        }
        if let path = FilePickerBreadcrumbBar.hitPath(at: point,
                                                      breadcrumbFrame: filePickerBreadcrumbFrame,
                                                      segmentFrames: filePickerBreadcrumbSegmentFrames) {
            fetchFilePicker(path: path)
            return
        }
        if filePickerListFrame.contains(point),
           filePickerScrollbarController?.handleMouseDown(at: rootLayer.convert(point, to: filePickerListLayer)) == true {
            return
        }
        guard filePickerListFrame.contains(point) else { return }
        if let hit = filePickerEntryFrames.first(where: { $0.frame.contains(point) }) {
            filePickerSelectedIndex = hit.index
            resetFilePickerTypeahead()
            updateFilePickerVisibleRows(rebuild: true)
            if clickCount >= 2 {
                activateFilePickerEntry(hit.entry)
            }
            return
        }
    }

    private func activateSelectedFilePickerEntry() {
        guard let selectedIndex = filePickerSelectedIndex,
              let entries = pendingFilePicker?.entries,
              entries.indices.contains(selectedIndex) else {
            return
        }
        activateFilePickerEntry(entries[selectedIndex])
    }

    private func activateFilePickerEntry(_ entry: FilePickerEntry) {
        if entry.isDirectory {
            fetchFilePicker(path: entry.path)
        } else {
            pendingFilePicker = nil
            renderFilePicker()
            perfPathInputController.setText(entry.path)
            setPerfPath(entry.path)
        }
    }

    private func moveFilePickerSelection(delta: Int) {
        guard let entries = pendingFilePicker?.entries,
              !entries.isEmpty else { return }
        let nextIndex = min(max((filePickerSelectedIndex ?? (delta > 0 ? -1 : entries.count)) + delta, 0), entries.count - 1)
        selectFilePickerIndex(nextIndex)
    }

    private func selectFilePickerIndex(_ index: Int) {
        guard let entries = pendingFilePicker?.entries,
              entries.indices.contains(index) else { return }
        filePickerSelectedIndex = index
        ensureFilePickerSelectionVisible()
        updateFilePickerVisibleRows(rebuild: true)
    }

    private func ensureFilePickerSelectionVisible() {
        guard let selectedIndex = filePickerSelectedIndex else { return }
        let rowTop = CGFloat(selectedIndex) * filePickerRowHeight
        let viewportHeight = max(filePickerListFrame.height, 1)
        if rowTop < filePickerScroll {
            filePickerScroll = rowTop
        } else if rowTop + filePickerRowHeight > filePickerScroll + viewportHeight {
            filePickerScroll = rowTop + filePickerRowHeight - viewportHeight
        }
        clampFilePickerScroll()
    }

    private func clampFilePickerSelection() {
        guard let count = pendingFilePicker?.entries.count,
              count > 0 else {
            filePickerSelectedIndex = nil
            return
        }
        if let selectedIndex = filePickerSelectedIndex,
           selectedIndex >= count {
            filePickerSelectedIndex = count - 1
        }
    }

    private func resetFilePickerTypeahead() {
        filePickerTypeaheadPrefix = ""
        filePickerTypeaheadLastUpdated = nil
    }

    private func handleFilePickerTypeahead(_ text: String) {
        guard let entries = pendingFilePicker?.entries,
              !entries.isEmpty else { return }
        let now = Date()
        if let last = filePickerTypeaheadLastUpdated,
           now.timeIntervalSince(last) > 1.0 {
            filePickerTypeaheadPrefix = ""
        }
        filePickerTypeaheadLastUpdated = now
        filePickerTypeaheadPrefix += text.lowercased()
        if selectFilePickerEntry(matchingPrefix: filePickerTypeaheadPrefix, in: entries, startingAfterSelection: false) {
            return
        }
        filePickerTypeaheadPrefix = text.lowercased()
        _ = selectFilePickerEntry(matchingPrefix: filePickerTypeaheadPrefix, in: entries, startingAfterSelection: true)
    }

    private func selectFilePickerEntry(matchingPrefix prefix: String, in entries: [FilePickerEntry], startingAfterSelection: Bool) -> Bool {
        guard !prefix.isEmpty else { return false }
        let start = startingAfterSelection ? (filePickerSelectedIndex ?? -1) + 1 : 0
        for offset in 0..<entries.count {
            let index = (start + offset) % entries.count
            if entries[index].name.lowercased().hasPrefix(prefix) {
                selectFilePickerIndex(index)
                return true
            }
        }
        return false
    }

    private func clampFilePickerScroll(contentHeight: CGFloat? = nil, viewportHeight: CGFloat? = nil) {
        let content = contentHeight ?? max(filePickerContentHeight, CGFloat(pendingFilePicker?.entries.count ?? 0) * filePickerRowHeight, 1)
        let viewport = viewportHeight ?? max(filePickerListFrame.height, 1)
        filePickerScroll = min(max(filePickerScroll, 0), max(content - viewport, 0))
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
        defer { notifyAccessibilityChanged() }
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

    private func perfPathTextFrame(fieldBounds: CGRect) -> CGRect {
        CGRect(x: 9,
               y: 7,
               width: max(fieldBounds.width - 18, 1),
               height: 16)
    }

    private func makePerfPathLine(text: String) -> CTLine {
        let attributed = NSAttributedString(string: text,
                                            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
        return CTLineCreateWithAttributedString(attributed)
    }

    private func offsetForCharacter(line: CTLine, index: Int, in text: String, maxWidth: CGFloat) -> CGFloat {
        let utf16Index = utf16Offset(forCharacterIndex: index, in: text)
        var secondaryOffset: CGFloat = 0
        let primary = CTLineGetOffsetForStringIndex(line, utf16Index, &secondaryOffset)
        let offset = max(primary, secondaryOffset)
        return offset.isFinite ? min(max(offset, 0), maxWidth) : 0
    }

    private func perfPathCursorPosition(at point: CGPoint) -> Int {
        let textFrame = perfPathTextFrame(fieldBounds: perfPathFrame)
        let localX = max(0, min(point.x - perfPathFrame.minX - textFrame.minX, textFrame.width))
        let text = perfPathInputController.text
        guard !text.isEmpty else { return 0 }
        let line = makePerfPathLine(text: text)
        let utf16Index = CTLineGetStringIndexForPosition(line, CGPoint(x: localX, y: 0))
        guard utf16Index != kCFNotFound else { return text.count }
        return characterIndex(forUTF16: utf16Index, in: text)
    }

    private func perfPathCaretRectInProcessList() -> CGRect {
        let textFrame = perfPathTextFrame(fieldBounds: perfPathFrame)
        let text = perfPathInputController.text
        let offset: CGFloat
        if text.isEmpty {
            offset = 0
        } else {
            let line = makePerfPathLine(text: text)
            offset = offsetForCharacter(line: line,
                                        index: perfPathInputController.cursorPosition,
                                        in: text,
                                        maxWidth: textFrame.width)
        }
        return CGRect(x: perfPathFrame.minX + textFrame.minX + offset,
                      y: perfPathFrame.minY + textFrame.minY + 1,
                      width: 1,
                      height: textFrame.height - 2)
    }

    private func focusProcessSearch(cursorPosition: Int, modifySelection: Bool) {
        if perfPathInputController.isFocused {
            blurPerfPath(commit: true)
        }
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
        clearProcessSearchMarkedTextState()
        updateProcessSearchDisplay()
        updateColors()
        updateTextInputState()
    }

    private func focusPerfPath(cursorPosition: Int, modifySelection: Bool) {
        blurProcessSearch()
        perfPathInputController.focus()
        perfPathInputController.setCursorPosition(cursorPosition, modifySelection: modifySelection)
        updateProcessRows()
        updateTextInputState()
    }

    private func blurPerfPath(commit: Bool) {
        guard perfPathInputController.isFocused else { return }
        if commit {
            commitPerfPathInput()
        }
        perfPathInputController.blur()
        updateProcessRows()
        updateTextInputState()
    }

    private func commitPerfPathInput() {
        let trimmed = perfPathInputController.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed != perfPath {
            perfPath = trimmed
            setPerfPath(trimmed)
        }
    }

    func textInputControllerDidChangeState() {
        updateProcessRows()
        updateTextInputState()
    }

    private func setProcessSearchText(_ text: String) {
        processSearchText = text
        processSearchCursorPosition = min(processSearchCursorPosition, processSearchText.count)
        processSearchSelectionAnchor = nil
        clearProcessSearchMarkedTextState()
        processScroll = 0
        rebuildProcessContent()
        updateProcessSearchDisplay()
        updateProcessScrollPosition()
        updateTextInputState()
    }

    private func insertProcessSearchText(_ text: String, replacementRange: Range<Int>?) {
        let range = replacementRange
            ?? processSearchMarkedRange
            ?? processSearchPendingMarkedRange
            ?? processSearchSelectionRange()
            ?? processSearchCursorPosition..<processSearchCursorPosition
        replaceProcessSearchText(range: range, with: text)
    }

    private func setMarkedProcessSearchText(_ text: String,
                                            selectedLocation: Int,
                                            selectedLength: Int,
                                            replacementRange: Range<Int>?) {
        let range = processSearchNormalizedRange(replacementRange)
            ?? processSearchMarkedRange
            ?? processSearchSelectionRange()
            ?? processSearchCursorPosition..<processSearchCursorPosition
        let lower = min(max(range.lowerBound, 0), processSearchText.count)
        processSearchMarkedRange = text.isEmpty ? nil : lower..<(lower + text.count)
        processSearchPendingMarkedRange = nil
        replaceProcessSearchText(range: range, with: text, clearsMarkedText: false)

        let selectedLower = min(max(selectedLocation, 0), text.count)
        let selectedUpper = min(max(selectedLower + selectedLength, selectedLower), text.count)
        if selectedUpper > selectedLower {
            processSearchSelectionAnchor = lower + selectedLower
            processSearchCursorPosition = lower + selectedUpper
        } else {
            processSearchSelectionAnchor = nil
            processSearchCursorPosition = lower + selectedLower
        }
        processScroll = 0
        rebuildProcessContent()
        updateProcessSearchDisplay()
        updateProcessScrollPosition()
        updateTextInputState()
    }

    private func replaceProcessSearchText(range: Range<Int>, with replacement: String, clearsMarkedText: Bool = true) {
        let lower = min(max(range.lowerBound, 0), processSearchText.count)
        let upper = min(max(range.upperBound, lower), processSearchText.count)
        let start = processSearchText.index(processSearchText.startIndex, offsetBy: lower)
        let end = processSearchText.index(processSearchText.startIndex, offsetBy: upper)
        processSearchText.replaceSubrange(start..<end, with: replacement)
        processSearchCursorPosition = lower + replacement.count
        processSearchSelectionAnchor = nil
        if clearsMarkedText {
            clearProcessSearchMarkedTextState()
        }
        processScroll = 0
        rebuildProcessContent()
        updateProcessSearchDisplay()
        updateProcessScrollPosition()
        updateTextInputState()
    }

    private func deleteProcessSearchBackward() {
        if deleteProcessSearchSelection() {
            return
        }
        guard processSearchCursorPosition > 0 else { return }
        clearProcessSearchMarkedTextState()
        replaceProcessSearchText(range: (processSearchCursorPosition - 1)..<processSearchCursorPosition, with: "")
    }

    private func deleteProcessSearchForward() {
        if deleteProcessSearchSelection() {
            return
        }
        guard processSearchCursorPosition < processSearchText.count else { return }
        clearProcessSearchMarkedTextState()
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
        clearProcessSearchMarkedTextState()
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
        clearProcessSearchMarkedTextState()
        processSearchSelectionAnchor = 0
        processSearchCursorPosition = processSearchText.count
        updateProcessSearchDisplay()
        updateTextInputState()
    }

    private func processSearchNormalizedRange(_ range: Range<Int>?) -> Range<Int>? {
        guard let range else { return nil }
        let lower = min(max(range.lowerBound, 0), processSearchText.count)
        let upper = min(max(range.upperBound, lower), processSearchText.count)
        return lower..<upper
    }

    private func clearProcessSearchMarkedTextState() {
        processSearchMarkedRange = nil
        processSearchPendingMarkedRange = nil
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
                                      keyEquivalentModifierMask: UInt32(truncatingIfNeeded: NSEvent.ModifierFlags.command.rawValue))
        ]
        outerframeHost.showContextMenu(menuID: menuID, items: items, at: point)
    }

    private func showPerfPathContextMenu(at point: CGPoint) {
        let menuID = UUID()
        perfPathContextMenuIDs.insert(menuID)
        let hasSelection = perfPathInputController.hasSelection
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
        default:
            break
        }
    }

    private func handlePerfPathContextMenuSelection(itemID: String) {
        switch itemID {
        case "cut":
            writeFocusedSelectionToPasteboard(cut: true)
        case "copy":
            writeFocusedSelectionToPasteboard(cut: false)
        case "paste":
            readPasteboardIntoFocusedField()
        default:
            break
        }
    }

    private func textPasteboardItems(_ text: String?) -> [OuterContentPasteboardItem] {
        guard let text, let data = text.data(using: .utf8) else { return [] }
        return [OuterContentPasteboardItem(representations: [
            OuterContentPasteboardRepresentation(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                                                 data: data)
        ])]
    }

    private func processSearchPasteboardItems() -> [OuterContentPasteboardItem] {
        textPasteboardItems(selectedProcessSearchText())
    }

    private func perfPathPasteboardItems() -> [OuterContentPasteboardItem] {
        textPasteboardItems(perfPathInputController.selectedTextContent())
    }

    private func selectedPasteboardItems() -> [OuterContentPasteboardItem] {
        if perfMachineUnsupported {
            return machineUnsupportedPasteboardItems()
        }
        if processSearchFocused {
            return processSearchPasteboardItems()
        }
        if perfPathInputController.isFocused {
            return perfPathPasteboardItems()
        }
        return []
    }

    private func writeProcessSearchSelectionToPasteboard(cut: Bool) {
        let items = processSearchPasteboardItems()
        guard !items.isEmpty else { return }
        outerframeHost.requestPasteboardWrite(items: items) { [weak self] granted in
            guard granted, cut else { return }
            self?.deleteProcessSearchSelection()
        }
    }

    private func writeFocusedSelectionToPasteboard(cut: Bool) {
        if processSearchFocused {
            writeProcessSearchSelectionToPasteboard(cut: cut)
            return
        }
        guard perfPathInputController.isFocused else { return }
        let items = perfPathPasteboardItems()
        guard !items.isEmpty else { return }
        outerframeHost.requestPasteboardWrite(items: items) { [weak self] granted in
            guard granted, cut else { return }
            _ = self?.perfPathInputController.cutSelectedTextContent()
        }
    }

    private func cutFocusedSelection() {
        if processSearchFocused {
            deleteProcessSearchSelection()
        } else if perfPathInputController.isFocused {
            _ = perfPathInputController.cutSelectedTextContent()
        }
    }

    private func readPasteboardIntoProcessSearch() {
        outerframeHost.requestPasteboardRead(typeIdentifiers: processSearchPasteboardTypeIdentifiers) { [weak self] granted, items in
            guard granted else { return }
            self?.insertProcessSearchPasteboardItems(items)
        }
    }

    private func readPasteboardIntoFocusedField() {
        outerframeHost.requestPasteboardRead(typeIdentifiers: processSearchPasteboardTypeIdentifiers) { [weak self] granted, items in
            guard granted else { return }
            self?.insertPasteboardItemsIntoFocusedField(items)
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

    private func insertPasteboardItemsIntoFocusedField(_ items: [OuterContentPasteboardItem]) {
        if processSearchFocused {
            insertProcessSearchPasteboardItems(items)
            return
        }
        guard perfPathInputController.isFocused else { return }
        for item in items {
            for representation in item.representations {
                if representation.typeIdentifier == NSPasteboard.PasteboardType.string.rawValue,
                   let string = String(data: representation.data, encoding: .utf8) {
                    perfPathInputController.pasteText(string)
                    return
                }
                if representation.typeIdentifier == NSPasteboard.PasteboardType.rtf.rawValue,
                   let attributed = NSAttributedString(rtf: representation.data, documentAttributes: nil) {
                    perfPathInputController.pasteText(attributed.string)
                    return
                }
            }
        }
    }

    private func updateTextInputState() {
        if perfMachineUnsupported {
            outerframeHost.setInputMode(.rawKeys)
            outerframeHost.setAcceptedPasteboardPasteTypes([])
            outerframeHost.sendTextInputGeometryUpdate(nil)
            return
        }
        let perfPathFocused = perfPathInputController.isFocused
        let inputMode: OuterframeContentInputMode = (processSearchFocused || perfPathFocused) ? [.textInput, .rawKeys] : .rawKeys
        outerframeHost.setInputMode(inputMode)
        outerframeHost.setAcceptedPasteboardPasteTypes((processSearchFocused || perfPathFocused) ? processSearchPasteboardTypeIdentifiers : [])
        guard showingSetup else {
            outerframeHost.sendTextInputGeometryUpdate(nil)
            return
        }

        if perfPathFocused {
            guard perfPathInputController.selectionRange == nil else {
                outerframeHost.sendTextInputGeometryUpdate(nil)
                return
            }
            let caretFrame = perfPathCaretRectInProcessList()
            let rootCaretFrame = processListLayer.convert(caretFrame, to: rootLayer)
            let topLeftY = rootLayer.bounds.height - rootCaretFrame.origin.y - rootCaretFrame.height
            let geometry = OuterframeContentTextInputGeometry(fieldID: Self.perfPathFieldID,
                                                              rect: CGRect(x: rootCaretFrame.origin.x,
                                                                           y: topLeftY,
                                                                           width: rootCaretFrame.width,
                                                                           height: rootCaretFrame.height))
            outerframeHost.sendTextInputGeometryUpdate(geometry)
            return
        }

        guard processSearchFocused else {
            outerframeHost.sendTextInputGeometryUpdate(nil)
            return
        }
        guard processSearchSelectionRange() == nil else {
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

    private func enabledEditCommands(in requestedCommands: OuterframeEditCommandSet) -> OuterframeEditCommandSet {
        if perfMachineUnsupported {
            var enabledCommands: OuterframeEditCommandSet = []
            if machineUnsupportedSelectedText() != nil, requestedCommands.contains(.copy) {
                enabledCommands.insert(.copy)
            }
            if requestedCommands.contains(.selectAll), !machineUnsupportedBodyText().isEmpty {
                enabledCommands.insert(.selectAll)
            }
            return enabledCommands
        }
        if perfPathInputController.isFocused {
            return perfPathInputController.enabledEditCommands(in: requestedCommands)
        }
        guard processSearchFocused else { return [] }

        var enabledCommands: OuterframeEditCommandSet = []
        if processSearchSelectionRange() != nil {
            if requestedCommands.contains(.copy) {
                enabledCommands.insert(.copy)
            }
            if requestedCommands.contains(.cut) {
                enabledCommands.insert(.cut)
            }
        }
        if requestedCommands.contains(.paste) {
            enabledCommands.insert(.paste)
        }
        if requestedCommands.contains(.selectAll), !processSearchText.isEmpty {
            enabledCommands.insert(.selectAll)
        }
        return enabledCommands
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

            let maxCPU = timelineYScale(for: profile)
            let duration = max(Double(profile.duration), profile.timeline.last?.end ?? 1)
            timelineBarsLayer.frame = chartRect
            timelineBarsLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            timelineBarsLayer.configure(profileID: profile.profileID,
                                        buckets: profile.timeline,
                                        duration: duration,
                                        maxCPU: maxCPU,
                                        barColor: timelineBarColor.cgColor)
            timelineLayer.addSublayer(timelineBarsLayer)

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

    private func timelineYScale(for profile: ProfileResponse) -> Double {
        max(profile.timeline.map(\.cpuPercent).max() ?? 0, 100)
    }

    private func timelineBucketIndex(for time: Double, in buckets: [TimelineBucket]) -> Int? {
        guard !buckets.isEmpty else { return nil }
        if time >= (buckets.last?.start ?? 0), time <= (buckets.last?.end ?? 0) {
            return buckets.count - 1
        }
        var low = 0
        var high = buckets.count
        while low < high {
            let mid = (low + high) / 2
            let bucket = buckets[mid]
            if time < bucket.start {
                high = mid
            } else if time >= bucket.end {
                low = mid + 1
            } else {
                return mid
            }
        }
        return nil
    }

    private func timelineBucketCenterX(_ bucket: TimelineBucket, chart: CGRect, duration: Double) -> CGFloat {
        let midpoint = (bucket.start + bucket.end) * 0.5
        return chart.minX + CGFloat(midpoint / duration) * chart.width
    }

    private func nearbyNonzeroTimelineBucket(at point: CGPoint) -> TimelineBucket? {
        guard let profile = lastProfile, !profile.timeline.isEmpty else { return nil }
        let chart = timelineChartRect()
        guard chart.insetBy(dx: -8, dy: -10).contains(point) else { return nil }
        let duration = max(Double(profile.duration), profile.timeline.last?.end ?? 1)
        let normalized = min(max((point.x - chart.minX) / max(chart.width, 1), 0), 1)
        let time = Double(normalized) * duration

        guard let startingIndex = timelineBucketIndex(for: time, in: profile.timeline) else { return nil }
        let exactBucket = profile.timeline[startingIndex]
        if exactBucket.samples > 0 {
            return exactBucket
        }

        let tolerance: CGFloat = 7
        var bestBucket: TimelineBucket?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        var left = startingIndex - 1
        while left >= 0 {
            let bucket = profile.timeline[left]
            let distance = abs(timelineBucketCenterX(bucket, chart: chart, duration: duration) - point.x)
            if distance > tolerance {
                break
            }
            if bucket.samples > 0, distance < bestDistance {
                bestBucket = bucket
                bestDistance = distance
            }
            left -= 1
        }

        var right = startingIndex + 1
        while right < profile.timeline.count {
            let bucket = profile.timeline[right]
            let distance = abs(timelineBucketCenterX(bucket, chart: chart, duration: duration) - point.x)
            if distance > tolerance {
                break
            }
            if bucket.samples > 0, distance < bestDistance {
                bestBucket = bucket
                bestDistance = distance
            }
            right += 1
        }

        return bestDistance <= tolerance ? bestBucket : nil
    }

    private func showTimelineTooltip(at point: CGPoint, rootPoint: CGPoint) -> Bool {
        guard let bucket = nearbyNonzeroTimelineBucket(at: point) else {
            hideTooltip()
            return false
        }
        let bucketMilliseconds = max(bucket.end - bucket.start, 0) * 1000
        let text = "\(String(format: "%.1f", bucket.cpuPercent))% (\(String(format: "%.2f", bucketMilliseconds)) ms)\n\(formatDuration(bucket.start)) - \(formatDuration(bucket.end))\nSamples: \(bucket.samples)"
        showTooltip(text: text, at: rootPoint)
        return true
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
        defer { notifyAccessibilityChanged() }
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

    private var pageBackgroundColor: NSColor {
        NSColor.controlBackgroundColor
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
        let enabled = !isBusy && (isRecording || (selectedPID != nil && perfUsable && !perfMachineUnsupported))
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

    private func makeButtonLayer(title: String, enabled: Bool = true) -> CALayer {
        let layer = CALayer()
        layer.addSublayer(makeButtonLabel(title))
        layer.sublayers?.first?.frame = layer.bounds.insetBy(dx: 10, dy: 6)
        styleButton(layer, enabled: enabled)
        return layer
    }

    private func makeSymbolLayer(_ symbolName: String, color: NSColor, renderSize: CGFloat = 32) -> CALayer {
        let layer = CALayer()
        updateSymbolLayer(layer, symbolName: symbolName, color: color, renderSize: renderSize)
        layer.contentsGravity = .resizeAspect
        layer.contentsScale = 2
        return layer
    }

    private func updateSymbolLayer(_ layer: CALayer,
                                   symbolName: String,
                                   color: NSColor,
                                   renderSize: CGFloat = 32) {
        guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: renderSize, weight: .regular)
        let image = baseImage.withSymbolConfiguration(configuration) ?? baseImage
        image.isTemplate = true
        let size = NSSize(width: renderSize * 2, height: renderSize * 2)
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
        layer.foregroundColor = resolvedCGColor(NSColor.labelColor)
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
