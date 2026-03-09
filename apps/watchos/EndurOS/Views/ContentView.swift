import SwiftUI

struct ContentView: View {
    private let accentIndigo = Color.indigo
    private let pageTransitionIn = AnyTransition.scale(scale: 0.92).combined(with: .opacity)
    private let pageTransitionOut = AnyTransition.scale(scale: 1.06).combined(with: .opacity)
    private let pageAnimation = Animation.spring(response: 0.34, dampingFraction: 0.88, blendDuration: 0.2)
    private let headerTitleTransition = AnyTransition.scale(scale: 0.94).combined(with: .opacity)
    private let headerTitleAnimation = Animation.spring(response: 0.28, dampingFraction: 0.9, blendDuration: 0.15)

    struct SessionSummary {
        let sportName: String
        let elapsed: TimeInterval
        let activeCalories: Double
        let totalCalories: Double
        let distanceKm: Double
        let speedKmh: Double
        let averageSpeedKmh: Double
        let maxSpeedKmh: Double
        let averagePace: Double?
        let highSpeedDistanceKm: Double
        let sprintDistanceKm: Double
        let sprintCount: Int
        let accelerationCount: Int
        let decelerationCount: Int
    }

    @StateObject private var location: LocationManager
    @StateObject private var workout: WorkoutManager

    @State private var sessionPage = 1
    @State private var pendingSport: WorkoutManager.SportProfile?
    @State private var countdownValue: Int?
    @State private var countdownProgress: CGFloat = 1
    @State private var countdownTask: Task<Void, Never>?
    @State private var summary: SessionSummary?
    @State private var activeTrackedSectionTitle: String?

    init() {
        let loc = LocationManager()
        _location = StateObject(wrappedValue: loc)
        _workout = StateObject(wrappedValue: WorkoutManager(location: loc))
    }

    var body: some View {
        ZStack(alignment: .top) {
            NavigationStack {
                ZStack {
                    if let summary {
                        summaryView(summary)
                            .id("summary")
                            .transition(.asymmetric(insertion: pageTransitionIn, removal: pageTransitionOut))
                    } else if let sport = pendingSport, let countdownValue {
                        countdownView(sport: sport, value: countdownValue)
                            .id("countdown-\(sport.id)")
                            .transition(.asymmetric(insertion: pageTransitionIn, removal: pageTransitionOut))
                    } else if !isShowingSessionPages {
                        sportSelectionView
                            .id("sports")
                            .transition(.asymmetric(insertion: pageTransitionIn, removal: pageTransitionOut))
                    } else {
                        sessionView
                            .id("session")
                            .transition(.asymmetric(insertion: pageTransitionIn, removal: pageTransitionOut))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, -4)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.hidden, for: .navigationBar)
                .animation(pageAnimation, value: transitionStateKey)
            }

            topBlurHeader
                .padding(.top, -44)
        }
        .task {
            await workout.requestAuthorization()
        }
        .onChange(of: workout.remoteStartSport?.id) { _, _ in
            guard let sport = workout.remoteStartSport else { return }
            sessionPage = 1
            startCountdown(for: sport)
            workout.clearRemoteStartRequest()
        }
    }

    private var topBlurHeader: some View {
        ZStack {
            if summary != nil {
                HStack {
                    Text("Summary")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.leading, 20)
                .padding(.trailing, 12)
            } else {
                HStack {
                    Text(topHeaderTitle)
                        .id(topHeaderTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .transition(.asymmetric(insertion: headerTitleTransition, removal: headerTitleTransition))
                    Spacer()
                }
                .padding(.leading, 20)
                .padding(.trailing, 12)
                .animation(headerTitleAnimation, value: topHeaderTitle)
            }

        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial)
        .ignoresSafeArea(edges: .horizontal)
    }

    private var topHeaderTitle: String {
        if summary != nil { return "Summary" }
        if let pendingSport { return pendingSport.displayName }
        if !isShowingSessionPages { return "Sports" }
        if sessionPage == 0, let activeTrackedSectionTitle { return activeTrackedSectionTitle }
        return workout.selectedSport?.displayName ?? "Workout"
    }

    private var isShowingSessionPages: Bool {
        switch workout.runState {
        case .running, .paused:
            return true
        default:
            return false
        }
    }

    private var sportSelectionView: some View {
        GeometryReader { scrollGeo in
            let viewportCenter = scrollGeo.size.height * 0.5

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(WorkoutManager.SportProfile.allCases) { sport in
                        GeometryReader { cardGeo in
                            let midY = cardGeo.frame(in: .named("sportsScroll")).midY
                            let distanceFromCenter = abs(midY - viewportCenter)
                            let normalized = min(distanceFromCenter / (scrollGeo.size.height * 0.82), 1)
                            let edgeBias = pow(normalized, 1.9)
                            let opacity = 1 - (edgeBias * 0.72)
                            let scale = 1 - (edgeBias * 0.09)
                            let tiltDirection: Double = midY < viewportCenter ? 1 : -1
                            let tiltDegrees = edgeBias * 9 * tiltDirection

                            sportCardButton(for: sport)
                                .scaleEffect(scale)
                                .opacity(opacity)
                                .rotation3DEffect(
                                    .degrees(tiltDegrees),
                                    axis: (x: 1, y: 0, z: 0),
                                    perspective: 0.65
                                )
                                .zIndex(1 - edgeBias)
                                .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.86), value: midY)
                        }
                        .frame(height: 88)
                    }
                }
                .padding(.vertical, 2)
            }
            .coordinateSpace(name: "sportsScroll")
        }
    }

    private func sportCardButton(for sport: WorkoutManager.SportProfile) -> some View {
        Button {
            sessionPage = 1
            startCountdown(for: sport)
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: sport.icon)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(accentIndigo)
                        .frame(width: 30, height: 30)

                    Text(sport.displayName)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    HStack(spacing: 3) {
                        Text("Start session")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Image(systemName: "play.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(accentIndigo)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 84)

                Button(action: {}) {
                    ZStack {
                        Circle()
                            .fill(accentIndigo.opacity(0.16))
                            .frame(width: 20, height: 20)

                        Image(systemName: "ellipsis")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(accentIndigo)
                            .frame(width: 20, height: 20)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .padding(.trailing, 8)
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accentIndigo.opacity(0.2))
            )
        }
        .buttonStyle(.plain)
    }

    private func countdownView(sport: WorkoutManager.SportProfile, value: Int) -> some View {
        VStack {
            Spacer(minLength: 0)

            VStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 8)
                        .frame(width: 112, height: 112)

                    Circle()
                        .trim(from: 0, to: countdownProgress)
                        .stroke(accentIndigo, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 112, height: 112)

                    Text("\(value)")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }

                Text("Starting \(sport.displayName) Session")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .offset(y: 14)

            Spacer(minLength: 0)
        }
    }

    private func startCountdown(for sport: WorkoutManager.SportProfile) {
        countdownTask?.cancel()
        withAnimation(pageAnimation) {
            pendingSport = sport
            countdownValue = 3
            countdownProgress = 1
        }

        countdownTask = Task {
            for value in stride(from: 3, through: 1, by: -1) {
                await MainActor.run {
                    countdownValue = value
                    countdownProgress = 1
                    withAnimation(.easeInOut(duration: 0.96)) {
                        countdownProgress = 0
                    }
                }
                try? await Task.sleep(nanoseconds: 960_000_000)
            }

            await MainActor.run {
                withAnimation(pageAnimation) {
                    pendingSport = nil
                    countdownValue = nil
                    countdownProgress = 1
                }
            }
            await workout.requestAuthorization()
            await MainActor.run {
                workout.start(sport: sport)
            }
        }
    }

    private var sessionView: some View {
        TabView(selection: $sessionPage) {
            trackedDataView
                .padding(.horizontal, 3)
                .tag(0)
            sessionMetricsView
                .padding(.horizontal, 3)
                .tag(1)
            controlsView
                .padding(.horizontal, 3)
                .tag(2)
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
    }

    private var sessionMetricsView: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 210
            VStack(spacing: compact ? 6 : 10) {
                HStack(spacing: 6) {
                    Image(systemName: workout.selectedSport?.icon ?? "figure.run")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(accentIndigo)
                        .frame(width: 28, height: 28, alignment: .leading)

                    Spacer(minLength: 0)

                    Text(formatTimeWithTenths(workout.elapsed))
                        .font(
                            compact
                            ? .system(size: 34, weight: .bold, design: .rounded).monospacedDigit()
                            : .system(size: 40, weight: .bold, design: .rounded).monospacedDigit()
                        )
                        .foregroundStyle(.yellow)
                }

                compactStatRow(symbol: "flame.fill", symbolColor: .orange, value: String(format: "%.0f", workout.caloriesKcal), label: "ACTIVE CAL")
                compactStatRow(symbol: "flame", symbolColor: .red, value: String(format: "%.0f", workout.caloriesKcal * 1.15), label: "TOTAL CAL")
                compactStatRow(symbol: "heart.fill", symbolColor: .pink, value: "--", label: "HEART BEAT")
                compactStatRow(symbol: "location.fill", symbolColor: .blue, value: String(format: "%.2f km", workout.distanceKm), label: "DISTANCE")

                Spacer(minLength: 0)
            }
        }
    }

    private func compactStatRow(symbol: String, symbolColor: Color, value: String, label: String) -> some View {
        HStack(spacing: 8) {
            Text(value)
                .font(.body.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(alignment: .leading)

            Spacer(minLength: 0)

            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(symbolColor)
                    .frame(width: 13, alignment: .leading)

                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 92, alignment: .leading)
        }
        .frame(minHeight: 24)
    }

    private var trackedDataView: some View {
        GeometryReader { scrollGeo in
            let viewportCenter = scrollGeo.size.height * 0.5

            ScrollView {
                VStack(spacing: 8) {
                    sectionHeader("Session", id: "Session")
                    metricCardWithDepth(symbol: "speedometer", title: "Speed", value: String(format: "%.1f km/h", workout.speedKmh), viewportCenter: viewportCenter)
                    metricCardWithDepth(symbol: "figure.run", title: "Pace", value: "\(formatPace(workout.currentPaceMinPerKm)) /km", viewportCenter: viewportCenter)
                    metricCardWithDepth(symbol: "gauge.with.needle", title: "Avg Speed", value: String(format: "%.1f km/h", workout.averageSpeedKmh), viewportCenter: viewportCenter)
                    metricCardWithDepth(symbol: "hare", title: "Max Speed", value: String(format: "%.1f km/h", workout.maxSpeedKmh), viewportCenter: viewportCenter)
                    metricCardWithDepth(symbol: "gauge.with.needle", title: "Avg Pace", value: "\(formatPace(workout.averagePaceMinPerKm)) /km", viewportCenter: viewportCenter)
                    metricCardWithDepth(symbol: "bolt", title: "HS Dist", value: String(format: "%.2f km", workout.highSpeedDistanceKm), viewportCenter: viewportCenter)

                    sectionHeader("Load", id: "Load")
                    metricCardWithDepth(symbol: "flame", title: "Sprint Dist", value: String(format: "%.2f km", workout.sprintDistanceKm), viewportCenter: viewportCenter)
                    metricCardWithDepth(symbol: "number.circle", title: "Sprints", value: "\(workout.sprintCount)", viewportCenter: viewportCenter)
                    metricCardWithDepth(symbol: "arrow.up.right", title: "Accels", value: "\(workout.accelerationCount)", viewportCenter: viewportCenter)
                    metricCardWithDepth(symbol: "arrow.down.right", title: "Decels", value: "\(workout.decelerationCount)", viewportCenter: viewportCenter)
                }
            }
            .coordinateSpace(name: "trackedDataScroll")
        }
        .onPreferenceChange(TrackedSectionOffsetKey.self) { offsets in
            // Keep active section title stable while scrolling through a section.
            // Switch only after a section header is actually under the blur header.
            let threshold: CGFloat = -34
            let resetThreshold: CGFloat = -2

            let candidate = offsets
                .filter { $0.value <= threshold }
                .max(by: { $0.value < $1.value })?
                .key

            var nextTitle = activeTrackedSectionTitle
            if let candidate {
                nextTitle = candidate
            } else {
                let sessionTop = offsets["Session"] ?? .greatestFiniteMagnitude
                if sessionTop > resetThreshold {
                    nextTitle = nil
                }
            }

            if activeTrackedSectionTitle != nextTitle {
                withAnimation(headerTitleAnimation) {
                    activeTrackedSectionTitle = nextTitle
                }
            }
        }
    }

    private func metricCardWithDepth(symbol: String, title: String, value: String, viewportCenter: CGFloat) -> some View {
        GeometryReader { cardGeo in
            let midY = cardGeo.frame(in: .named("trackedDataScroll")).midY
            let distanceFromCenter = abs(midY - viewportCenter)
            let normalized = min(distanceFromCenter / (viewportCenter * 1.6), 1)
            let edgeBias = pow(normalized, 1.9)
            let opacity = 1 - (edgeBias * 0.74)
            let scale = 1 - (edgeBias * 0.12)
            let blurRadius = edgeBias * 1.6
            let tiltDirection: Double = midY < viewportCenter ? 1 : -1
            let tiltDegrees = edgeBias * 7 * tiltDirection

            metricCard(symbol: symbol, title: title, value: value)
                .scaleEffect(scale)
                .opacity(opacity)
                .blur(radius: blurRadius)
                .rotation3DEffect(
                    .degrees(tiltDegrees),
                    axis: (x: 1, y: 0, z: 0),
                    perspective: 0.65
                )
                .zIndex(1 - edgeBias)
                .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.86), value: midY)
        }
        .frame(height: 58)
    }

    private var controlsView: some View {
        VStack {
            Spacer(minLength: 0)

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: workout.selectedSport?.icon ?? "figure.run")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(accentIndigo)
                        .frame(width: 24, height: 24)

                    Text("Duration")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 4)

                    Text(formatTime(workout.elapsed))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 10)
                .frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accentIndigo.opacity(0.22))
                )

                HStack(spacing: 8) {
                    Button {
                        if workout.runState == .running {
                            workout.pause()
                        } else if workout.runState == .paused {
                            workout.resume()
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: workout.runState == .running ? "pause" : "play")
                                .font(.headline.bold())
                            Text(workout.runState == .running ? "Pause" : "Resume")
                                .font(.caption2)
                        }
                        .foregroundStyle(workout.runState == .running ? .orange : Color(red: 0.75, green: 1.0, blue: 0.15))
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill((workout.runState == .running ? Color.orange : Color(red: 0.75, green: 1.0, blue: 0.15)).opacity(0.16))
                        )
                    }
                    .buttonStyle(.plain)

                    Button(role: .destructive) {
                        withAnimation(pageAnimation) {
                            summary = buildSummary()
                        }
                        workout.stopAndReset()
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: "xmark")
                                .font(.headline.bold())
                            Text("End")
                                .font(.caption2)
                        }
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.red.opacity(0.16))
                        )
                    }
                    .buttonStyle(.plain)
                }

                if case .error(let message) = workout.runState {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer(minLength: 0)
        }
    }

    private func summaryView(_ summary: SessionSummary) -> some View {
        ScrollView {
            VStack(spacing: 10) {
                summarySection(
                    title: "Session",
                    rows: [
                        ("Time", formatTime(summary.elapsed)),
                        ("Distance", String(format: "%.2f km", summary.distanceKm)),
                        ("Active Cal", String(format: "%.0f", summary.activeCalories)),
                        ("Total Cal", String(format: "%.0f", summary.totalCalories))
                    ]
                )

                summarySection(
                    title: "Speed",
                    rows: [
                        ("Live", String(format: "%.1f km/h", summary.speedKmh)),
                        ("Average", String(format: "%.1f km/h", summary.averageSpeedKmh)),
                        ("Max", String(format: "%.1f km/h", summary.maxSpeedKmh)),
                        ("Avg Pace", "\(formatPace(summary.averagePace)) /km")
                    ]
                )

                summarySection(
                    title: "Load",
                    rows: [
                        ("HS Dist", String(format: "%.2f km", summary.highSpeedDistanceKm)),
                        ("Sprint Dist", String(format: "%.2f km", summary.sprintDistanceKm)),
                        ("Sprints", "\(summary.sprintCount)"),
                        ("Accels", "\(summary.accelerationCount)"),
                        ("Decels", "\(summary.decelerationCount)")
                    ]
                )

                Button("Done") {
                    withAnimation(pageAnimation) {
                        self.summary = nil
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.blue)
                .padding(.top, 4)
            }
        }
    }

    private func summarySection(title: String, rows: [(String, String)]) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)

            ForEach(rows, id: \.0) { row in
                HStack {
                    Text(row.0.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(row.1)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(accentIndigo.opacity(0.2))
                )
            }
        }
    }

    private func buildSummary() -> SessionSummary {
        SessionSummary(
            sportName: workout.selectedSport?.displayName ?? "Workout",
            elapsed: workout.elapsed,
            activeCalories: workout.caloriesKcal,
            totalCalories: workout.caloriesKcal * 1.15,
            distanceKm: workout.distanceKm,
            speedKmh: workout.speedKmh,
            averageSpeedKmh: workout.averageSpeedKmh,
            maxSpeedKmh: workout.maxSpeedKmh,
            averagePace: workout.averagePaceMinPerKm,
            highSpeedDistanceKm: workout.highSpeedDistanceKm,
            sprintDistanceKm: workout.sprintDistanceKm,
            sprintCount: workout.sprintCount,
            accelerationCount: workout.accelerationCount,
            decelerationCount: workout.decelerationCount
        )
    }

    private func sectionHeader(_ text: String, id: String) -> some View {
        HStack {
            Text(text)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.top, 2)
        .padding(.bottom, 2)
        .padding(.horizontal, 8)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: TrackedSectionOffsetKey.self,
                    value: [id: proxy.frame(in: .named("trackedDataScroll")).minY]
                )
            }
        )
    }

    private func metricCard(symbol: String, title: String, value: String) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(accentIndigo)
                    .frame(width: 24, height: 24, alignment: .leading)

                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Spacer(minLength: 0)

            Text(value)
                .font(.callout.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(alignment: .trailing)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .frame(minHeight: 56)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(accentIndigo.opacity(0.2))
        )
    }

    private func formatTime(_ t: TimeInterval) -> String {
        let s = Int(t)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%02d:%02d", m, sec)
    }

    private func formatPace(_ minPerKm: Double?) -> String {
        guard let minPerKm, minPerKm.isFinite else { return "--:--" }
        let totalSeconds = Int((minPerKm * 60.0).rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formatTimeWithTenths(_ t: TimeInterval) -> String {
        let s = max(0, t)
        let minutes = Int(s) / 60
        let seconds = Int(s) % 60
        let tenths = Int((s * 10).truncatingRemainder(dividingBy: 10))
        return String(format: "%02d:%02d.%d", minutes, seconds, tenths)
    }

    private var transitionStateKey: String {
        if summary != nil { return "summary" }
        if let pendingSport {
            return "countdown-\(pendingSport.id)"
        }
        if workout.runState == .idle { return "sports" }
        return "session"
    }
}

private struct TrackedSectionOffsetKey: PreferenceKey {
    static var defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

#Preview {
    ContentView()
}
