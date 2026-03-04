import SwiftUI
import Combine

struct ContentView: View {
    @State private var isRunning = false
    @State private var speedKmh: Double = 0
    @State private var distanceKm: Double = 0
    @State private var elapsed: TimeInterval = 0

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: 4) {
                Text("Speed")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(String(format: "%.1f", speedKmh))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("km/h")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                metricBlock(title: "Dist", value: String(format: "%.2f", distanceKm), unit: "km")
                metricBlock(title: "Time", value: formatTime(elapsed), unit: "")
            }

            HStack(spacing: 8) {
                Button {
                    isRunning.toggle()
                    if !isRunning {
                        speedKmh = 0
                    }
                } label: {
                    Text(isRunning ? "Pause" : "Start")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    isRunning = false
                    speedKmh = 0
                    distanceKm = 0
                    elapsed = 0
                } label: {
                    Text("Stop")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 8)
        .onReceive(timer) { _ in
            guard isRunning else { return }
            elapsed += 1

            // TEMP fake movement so UI behaves like a tracker.
            // We'll replace this with real GPS + HealthKit next.
            let target = 18.0 // km/h
            speedKmh = min(target, speedKmh + 1.2)
            distanceKm += (speedKmh / 3600.0)
        }
    }

    private func metricBlock(title: String, value: String, unit: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.body, design: .rounded).weight(.semibold))
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(6)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let s = Int(t)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }
}

#Preview {
    ContentView()
}
