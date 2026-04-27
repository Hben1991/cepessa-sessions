import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct BatteryEntry: TimelineEntry {
    let date: Date
    let info: DeviceBatteryInfo
}

// MARK: - Timeline Provider

struct BatteryTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> BatteryEntry {
        BatteryEntry(
            date: Date(),
            info: DeviceBatteryInfo(
                deviceName: "Cepessa",
                batteryLevel: 85,
                deviceType: "cepessa",
                isConnected: true,
                lastUpdated: Date(),
                isMuted: false
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (BatteryEntry) -> Void) {
        completion(BatteryEntry(date: Date(), info: DeviceBatteryInfo.fromSharedDefaults()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BatteryEntry>) -> Void) {
        let info = DeviceBatteryInfo.fromSharedDefaults()
        let entry = BatteryEntry(date: Date(), info: info)
        // 5-minute fallback refresh; the app pushes instant updates via
        // WidgetCenter.shared.reloadAllTimelines on battery or mute state changes.
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 5, to: Date())!
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

// MARK: - Widget Definition

struct CepessaBatteryWidget: Widget {
    let kind: String = "CepessaBatteryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BatteryTimelineProvider()) { entry in
            if #available(iOS 17.0, *) {
                BatteryWidgetEntryView(entry: entry)
                    .containerBackground(.fill.tertiary, for: .widget)
            } else {
                BatteryWidgetEntryView(entry: entry)
            }
        }
        .configurationDisplayName("Cepessa Battery")
        .description("Shows your Cepessa device battery level and mic state.")
        .supportedFamilies([.accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Widget Entry View

struct BatteryWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: BatteryEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            AccessoryRectangularView(info: entry.info)
        default:
            AccessoryInlineView(info: entry.info)
        }
    }
}

// MARK: - Lock Screen: Rectangular

struct AccessoryRectangularView: View {
    let info: DeviceBatteryInfo

    var body: some View {
        HStack(spacing: 0) {
            // Left — device logo
            Image("cepessa-logo")
                .resizable()
                .renderingMode(.template)
                .scaledToFit()
                .frame(width: 36, height: 36)
                .foregroundColor(.primary)

            Spacer(minLength: 4)

            if info.isConnected {
                // Center — battery %
                Group {
                    if info.batteryLevel >= 0 {
                        Text("\(info.batteryLevel)%")
                    } else {
                        Text("--%")
                            .foregroundColor(.secondary)
                    }
                }
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)

                Spacer(minLength: 4)

                // Right — mute state
                Image(systemName: info.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(info.isMuted ? Color(red: 1.0, green: 0.23, blue: 0.19) : .primary)
                    .frame(width: 36)
            } else {
                // Disconnected
                Text("Connect\ndevice")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.25))
        )
    }
}

// MARK: - Lock Screen: Inline

struct AccessoryInlineView: View {
    let info: DeviceBatteryInfo

    var body: some View {
        if info.isConnected && info.batteryLevel >= 0 {
            Label("\(displayName) \(info.batteryLevel)%", systemImage: deviceIcon)
        } else {
            Label("\(displayName) --", systemImage: deviceIcon)
        }
    }

    private var displayName: String {
        info.deviceName.isEmpty || info.deviceName == "Unknown" ? "Cepessa" : info.deviceName
    }

    private var deviceIcon: String {
        switch info.deviceType.lowercased() {
        case "applewatch": return "applewatch"
        case "openglass", "frame": return "eyeglasses"
        default: return "mic.fill"
        }
    }
}

// MARK: - Previews

#if DEBUG
struct CepessaBatteryWidget_Previews: PreviewProvider {
    static var previews: some View {
        let connected = BatteryEntry(
            date: Date(),
            info: DeviceBatteryInfo(
                deviceName: "Cepessa DevKit",
                batteryLevel: 98,
                deviceType: "cepessa",
                isConnected: true,
                lastUpdated: Date(),
                isMuted: false
            )
        )
        let muted = BatteryEntry(
            date: Date(),
            info: DeviceBatteryInfo(
                deviceName: "Cepessa",
                batteryLevel: 72,
                deviceType: "cepessa",
                isConnected: true,
                lastUpdated: Date(),
                isMuted: true
            )
        )
        let disconnected = BatteryEntry(
            date: Date(),
            info: DeviceBatteryInfo(
                deviceName: "Cepessa",
                batteryLevel: -1,
                deviceType: "cepessa",
                isConnected: false,
                lastUpdated: Date.distantPast,
                isMuted: false
            )
        )

        Group {
            BatteryWidgetEntryView(entry: connected)
                .previewContext(WidgetPreviewContext(family: .accessoryRectangular))
                .previewDisplayName("Rectangular – Connected")
            BatteryWidgetEntryView(entry: muted)
                .previewContext(WidgetPreviewContext(family: .accessoryRectangular))
                .previewDisplayName("Rectangular – Muted")
            BatteryWidgetEntryView(entry: disconnected)
                .previewContext(WidgetPreviewContext(family: .accessoryRectangular))
                .previewDisplayName("Rectangular – Disconnected")
            BatteryWidgetEntryView(entry: connected)
                .previewContext(WidgetPreviewContext(family: .accessoryInline))
                .previewDisplayName("Inline")
        }
    }
}
#endif
