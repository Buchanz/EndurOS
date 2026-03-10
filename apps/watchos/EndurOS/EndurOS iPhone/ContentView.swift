//
//  ContentView.swift
//  EndurOS iPhone
//
//  Created by Tyler Buchanan on 2026-03-05.
//

import SwiftUI
import UIKit
import Contacts
import PhotosUI

struct ContentView: View {
    @EnvironmentObject private var sync: PhoneSyncManager
    @EnvironmentObject private var auth: AuthSessionManager

    private enum UnitSystem: CaseIterable {
        case metric
        case imperial

        var label: String {
            switch self {
            case .metric: return "Metric (km, kg)"
            case .imperial: return "Imperial (mi, lb)"
            }
        }
    }

private enum PaceUnit: CaseIterable {
        case perKm
        case perMile

        var label: String {
            switch self {
            case .perKm: return "min/km"
            case .perMile: return "min/mi"
            }
        }
    }

    @State private var selectedTab: AppTab = .sports
    @State private var showingProfile = false
    @State private var selectedPhotoItem: PhotosPickerItem?

    @State private var selectedSportDetail: SportCardData?
    @State private var hiddenSessionIDs: Set<String> = []
    @State private var searchText = ""
    @State private var selectedSummarySportFilter: String = "All"
    @FocusState private var isSearchFieldFocused: Bool
    @State private var activeShare: SharePayload?
    @State private var sportsSortMode: SportsSortMode = .mostRecent
    @State private var dismissedSuggestionIDs: Set<String> = []
    @State private var contactsAuthorization: CNAuthorizationStatus = CNContactStore.authorizationStatus(for: .contacts)
    @State private var contactInviteCandidates: [ContactInviteCandidate] = []
    @State private var contactsErrorMessage: String?
    @State private var showingInviteContacts = false
    @State private var inviteSearchText = ""
    @State private var showingUnitsSheet = false
    @State private var showingPrivacySheet = false
    @State private var showingHealthSheet = false
    @State private var unitSystem: UnitSystem = .metric
    @State private var paceUnit: PaceUnit = .perKm
    @State private var shareWithFriends = true
    @State private var shareWithAppAnalytics = true
    @State private var shareForCoachInsights = true
    @State private var trackHeartRate = true
    @State private var trackLocation = true
    @State private var trackWorkoutData = true
    @AppStorage("profile_initials_v1") private var profileInitials: String = "TB"
    @AppStorage("profile_photo_data_v1") private var profilePhotoData: Data = Data()

    private let background = Color.black
    private let surface = Color(red: 0.13, green: 0.15, blue: 0.23)
    private let elevated = Color(red: 0.18, green: 0.21, blue: 0.31)
    private let sportsContainer = Color(red: 0.11, green: 0.12, blue: 0.18)
    private let summaryContainer = Color(red: 0.16, green: 0.16, blue: 0.17)
    private let detailContainer = Color(red: 0.15, green: 0.15, blue: 0.16)
    private let mutedText = Color.white.opacity(0.70)
    private let accent = Color.indigo

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                sportsContent
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { navToolbar }
            }
            .tabItem { Label("Sports", systemImage: "figure.run") }
            .tag(AppTab.sports)

            NavigationStack {
                homeContent
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { navToolbar }
            }
            .tabItem { Label("Summary", systemImage: "chart.bar.fill") }
            .tag(AppTab.home)

            NavigationStack {
                summaryContent
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { navToolbar }
            }
            .tabItem { Label("History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") }
            .tag(AppTab.summary)

            NavigationStack {
                sharingContent
                    .navigationTitle("")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { navToolbar }
            }
            .tabItem { Label("Sharing", systemImage: "person.2") }
            .tag(AppTab.sharing)
        }
        .preferredColorScheme(.dark)
        .tint(.white)
        .sheet(isPresented: $showingProfile) {
            profileSheet
        }
        .sheet(item: $selectedSportDetail) { item in
            sportDetailSheet(item)
        }
        .sheet(item: $activeShare) { payload in
            ActivityShareSheet(items: [payload.text])
        }
        .sheet(isPresented: $showingInviteContacts) {
            inviteContactsSheet
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self), !data.isEmpty {
                    await MainActor.run { profilePhotoData = data }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            persistentSearchAccessoryBar
                .padding(.horizontal, 20)
                .padding(.bottom, isSearchFieldFocused ? 8 : 56)
                .animation(.easeInOut(duration: 0.18), value: isSearchFieldFocused)
        }
    }

    private var homeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageTitle("Summary")
                progressionTrackerCard
                sessionsOverviewCard
            }
            .padding()
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .background(background.ignoresSafeArea())
    }

    private var sportsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageTitle("Sports")
                ForEach(filteredSportCards) { item in
                    sportCard(item)
                }
            }
            .padding()
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .background(background.ignoresSafeArea())
    }

    private var summaryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                pageTitle("History")
                summarySportFilterCarousel
                if groupedSummarySessionsByMonth.isEmpty {
                    emptyState
                } else {
                    ForEach(groupedSummarySessionsByMonth, id: \.month) { bucket in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(bucket.month)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)

                            ForEach(bucket.sessions) { session in
                                NavigationLink {
                                    workoutSessionDetailView(session)
                                } label: {
                                    historyRow(session)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding()
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .background(background.ignoresSafeArea())
    }

    private var summarySportFilterCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(summarySportOptions, id: \.self) { option in
                    let isActive = selectedSummarySportFilter == option
                    Button {
                        selectedSummarySportFilter = option
                    } label: {
                        Text(option)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(isActive ? .black : .white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                isActive
                                ? AnyShapeStyle(accent)
                                : AnyShapeStyle(Color.gray.opacity(0.35)),
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var sharingContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                pageTitle("Sharing")
                sharingHeroCard

                if contactsAuthorization == .authorized {
                    Text("FRIEND SUGGESTIONS")
                        .font(.headline.weight(.medium))
                        .foregroundStyle(.secondary)

                    if visibleSuggestions.isEmpty {
                        Text("No contact suggestions yet.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(visibleSuggestions) { friend in
                                    friendSuggestionCard(friend)
                                }
                            }
                        }
                    }
                }

            }
            .padding()
            .padding(.bottom, 20)
            .task {
                refreshContactsState()
                if contactsAuthorization == .notDetermined {
                    requestContactsAccess(openInviteAfterGrant: false)
                }
            }
        }
        .scrollIndicators(.hidden)
        .background(background.ignoresSafeArea())
    }

    @ToolbarContentBuilder
    private var navToolbar: some ToolbarContent {
        if selectedTab == .sharing {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    openInviteFlow()
                } label: {
                    Image(systemName: "person.badge.plus")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
        }

        if selectedTab == .sports {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(SportsSortMode.allCases, id: \.self) { mode in
                        Button {
                            sportsSortMode = mode
                        } label: {
                            HStack {
                                Text(mode.label)
                                if sportsSortMode == mode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                showingProfile = true
            } label: {
                profileToolbarAvatar(size: 30)
            }
            .buttonStyle(.plain)
        }
    }

    private var sharingHeroCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.gray)
                .padding(.top, 2)

            Text("Share Activity")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)

            Text("Invite friends to share workouts, get inspired, and cheer each other on.")
                .font(.body)
                .foregroundStyle(mutedText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)

            Button {
                openInviteFlow()
            } label: {
                Text("Invite a Friend")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 9)
                    .background(Color.white.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(summaryContainer, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func friendSuggestionCard(_ friend: ContactInviteCandidate) -> some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                Button {
                    dismissedSuggestionIDs.insert(friend.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }

            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.64, green: 0.74, blue: 0.92), Color(red: 0.47, green: 0.53, blue: 0.84)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 88, height: 88)
                .overlay(
                    Text(friend.initials)
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                )

            Text(friend.name)
                .font(.headline.weight(.medium))
                .foregroundStyle(.white)
            Text("From Contacts")
                .font(.subheadline)
                .foregroundStyle(mutedText)

            Button {
                // TODO: send invite to selected contact once backend invite flow exists.
            } label: {
                Text("INVITE")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.10), in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
        .frame(width: 170)
        .padding(10)
        .background(summaryContainer, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var persistentSearchAccessoryBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isSearchFieldFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func pageTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 36, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, -30)
            .padding(.bottom, 2)
    }

    private func sportCard(_ item: SportCardData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Image(systemName: item.icon)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 56, height: 56, alignment: .leading)

                Spacer()

                Button {
                    selectedSportDetail = item
                } label: {
                    Circle()
                        .fill(accent)
                        .frame(width: 42, height: 42)
                        .overlay(
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(background)
                        )
                }
                .buttonStyle(.plain)
            }

            Text(item.sport)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)

            HStack(spacing: 8) {
                sportMetricPill(
                    symbol: "clock",
                    text: item.lastSession.map { sync.formattedDuration($0.durationSec) } ?? "--"
                )
                sportMetricPill(
                    symbol: "location",
                    text: item.lastSession.map { String(format: "%.2f km", $0.distanceKm) } ?? "--"
                )
                sportMetricPill(
                    symbol: "flame",
                    text: item.lastSession.map { "\(Int($0.activeCalories)) cal" } ?? "--"
                )
            }
        }
        .padding(16)
        .background(sportsContainer, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func sportMetricPill(symbol: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(.white.opacity(0.92))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var progressionTrackerCard: some View {
        let sprintGoal = 30.0
        let speedGoal = 30.0
        let sessionsGoal = 5.0
        let sprintProgress = GoalProgress(current: Double(weeklySprints), goal: sprintGoal)
        let speedProgress = GoalProgress(current: weeklyTopSpeedKmh, goal: speedGoal)
        let sessionsProgress = GoalProgress(current: Double(weeklySessionCount), goal: sessionsGoal)
        return VStack(alignment: .leading, spacing: 14) {
            Text("Goal Progression")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)

            HStack(spacing: 40) {
                Spacer(minLength: 0)
                ringCluster(
                    moveProgress: sprintProgress.progress,
                    exerciseProgress: speedProgress.progress,
                    standProgress: sessionsProgress.progress
                )
                .frame(width: 142, height: 142)

                VStack(alignment: .leading, spacing: 0) {
                    ringLegendRow("Sprints", "\(weeklySprints)/\(Int(sprintGoal))", color: .purple)
                    Spacer(minLength: 0)
                    ringLegendRow("Top Speed", String(format: "%.1f/%.0f km/h", weeklyTopSpeedKmh, speedGoal), color: .indigo)
                    Spacer(minLength: 0)
                    ringLegendRow("Sessions", "\(weeklySessionCount)/\(Int(sessionsGoal))", color: .blue)
                }
                .frame(width: 170, height: 132, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(summaryContainer, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func ringCluster(moveProgress: Double, exerciseProgress: Double, standProgress: Double) -> some View {
        ZStack {
            progressRing(progress: min(1, moveProgress), color: .purple, lineWidth: 16)
                .frame(width: 134, height: 134)
            progressRing(progress: min(1, exerciseProgress), color: .indigo, lineWidth: 14)
                .frame(width: 102, height: 102)
            progressRing(progress: min(1, standProgress), color: .blue, lineWidth: 12)
                .frame(width: 72, height: 72)
        }
    }

    private func progressRing(progress: Double, color: Color, lineWidth: CGFloat) -> some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }

    private func ringLegendRow(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
            Text(value)
                .font(.title3.weight(.bold))
                .foregroundStyle(color)
        }
    }

    private func sharingSessionTile(_ session: BackendSession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: iconForNormalizedSport(normalizeSportName(session.sport)))
                .font(.title3.weight(.semibold))
                .foregroundStyle(accent)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(normalizeSportName(session.sport))
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(sync.formattedDate(session.startedAt))
                    .font(.caption)
                    .foregroundStyle(mutedText)
            }

            Spacer()

            Button {
                activeShare = SharePayload(text: sync.shareText(for: session))
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.regularMaterial, in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func summaryTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(mutedText)
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func summaryStatCard(title: String, subtitle: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(mutedText)
                .lineLimit(2)

            Spacer(minLength: 0)

            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(accent)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .leading)
        .padding(12)
        .background(surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func sessionHighlightTile(_ session: BackendSession) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(accent.opacity(0.2))
                .frame(width: 46, height: 46)
                .overlay(
                    Image(systemName: iconForNormalizedSport(normalizeSportName(session.sport)))
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(accent)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(normalizeSportName(session.sport))
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(sync.formattedDate(session.startedAt))
                    .font(.caption)
                    .foregroundStyle(mutedText)
            }

            Spacer()

            Text(String(format: "%.2f km", session.distanceKm))
                .font(.title3.weight(.bold))
                .foregroundStyle(accent)
        }
        .padding(.vertical, 2)
    }

    private var sessionsOverviewCard: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ],
            spacing: 10
        ) {
            NavigationLink {
                sessionsHistoryView
            } label: {
                summarySquareCard(
                    title: "Sessions",
                    icon: visibleSessions.first.map { iconForNormalizedSport(normalizeSportName($0.sport)) } ?? "figure.run",
                    primary: "\(visibleSessions.count)",
                    secondary: "Total"
                )
            }
            .buttonStyle(.plain)

            summarySquareCard(
                title: "Awards",
                icon: "medal.star.fill",
                primary: "\(max(0, visibleSessions.count / 10))",
                secondary: "Unlocked"
            )

            summarySquareCard(
                title: "Distance",
                icon: "location.fill",
                primary: String(format: "%.1f km", weeklyDistanceKm),
                secondary: "This Week"
            )

            summarySquareCard(
                title: "Calories",
                icon: "flame.fill",
                primary: "\(Int(weeklyActiveCalories))",
                secondary: "This Week"
            )
        }
    }

    private func summarySquareCard(
        title: String,
        icon: String,
        primary: String,
        secondary: String,
        showsArrow: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(title)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                if showsArrow {
                    Circle()
                        .fill(Color.white.opacity(0.10))
                        .frame(width: 26, height: 26)
                        .overlay(
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Circle()
                .fill(accent.opacity(0.2))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: icon)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(accent)
                )

            Text(primary)
                .font(.title2.weight(.bold))
                .foregroundStyle(accent)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(secondary)
                .font(.caption)
                .foregroundStyle(mutedText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(12)
        .background(summaryContainer, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .aspectRatio(1, contentMode: .fit)
    }

    private var sessionsHistoryView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(groupedSessionsByMonth, id: \.month) { bucket in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(bucket.month)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.white)

                        ForEach(bucket.sessions) { session in
                            NavigationLink {
                                workoutSessionDetailView(session)
                            } label: {
                                historyRow(session)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding()
            .padding(.bottom, 20)
        }
        .background(background.ignoresSafeArea())
        .navigationTitle("Sessions History")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func historyRow(_ session: BackendSession) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(accent.opacity(0.2))
                .frame(width: 60, height: 60)
                .overlay(
                    Image(systemName: iconForNormalizedSport(normalizeSportName(session.sport)))
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(accent)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(normalizeSportName(session.sport))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(String(format: "%.2f km · %@", session.distanceKm, sync.formattedDuration(session.durationSec)))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(accent)
            }

            Spacer()

            Text(dayOrDateText(session.startedAt))
                .font(.caption)
                .foregroundStyle(mutedText)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .padding(12)
        .background(summaryContainer, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func workoutSessionDetailView(_ session: BackendSession) -> some View {
        let sport = normalizeSportName(session.sport)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Circle()
                        .fill(accent.opacity(0.2))
                        .frame(width: 84, height: 84)
                        .overlay(
                            Image(systemName: iconForNormalizedSport(sport))
                                .font(.system(size: 34, weight: .semibold))
                                .foregroundStyle(accent)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(sport)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.white)
                        Text(sessionTimeRange(session))
                            .font(.headline)
                            .foregroundStyle(mutedText)
                        Label(locationName(for: session), systemImage: "location.fill")
                            .font(.subheadline)
                            .foregroundStyle(mutedText)
                    }
                }

                Text("Workout Details")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 10) {
                    detailRow(
                        leftTitle: "Workout Time",
                        leftValue: sync.formattedDuration(session.durationSec),
                        leftColor: .yellow,
                        rightTitle: "Distance",
                        rightValue: String(format: "%.2f km", session.distanceKm),
                        rightColor: .cyan
                    )
                    Divider().overlay(Color.white.opacity(0.14))
                    detailRow(
                        leftTitle: "Active Calories",
                        leftValue: "\(Int(session.activeCalories)) cal",
                        leftColor: .pink,
                        rightTitle: "Total Calories",
                        rightValue: "\(Int(session.totalCalories)) cal",
                        rightColor: .pink
                    )
                    Divider().overlay(Color.white.opacity(0.14))
                    detailRow(
                        leftTitle: "Avg Speed",
                        leftValue: String(format: "%.1f km/h", session.averageSpeedKmh),
                        leftColor: .purple,
                        rightTitle: "Max Speed",
                        rightValue: String(format: "%.1f km/h", session.maxSpeedKmh),
                        rightColor: .orange
                    )
                    Divider().overlay(Color.white.opacity(0.14))
                    detailRow(
                        leftTitle: "Avg Pace",
                        leftValue: formatPace(session.averagePaceMinPerKm),
                        leftColor: .mint,
                        rightTitle: "Sprints",
                        rightValue: "\(session.sprintCount ?? 0)",
                        rightColor: .indigo
                    )
                    Divider().overlay(Color.white.opacity(0.14))
                    detailRow(
                        leftTitle: "Sprint Dist",
                        leftValue: String(format: "%.2f km", session.sprintDistanceKm ?? 0),
                        leftColor: .blue,
                        rightTitle: "High-Speed Dist",
                        rightValue: String(format: "%.2f km", session.highSpeedDistanceKm ?? 0),
                        rightColor: .teal
                    )
                    Divider().overlay(Color.white.opacity(0.14))
                    detailRow(
                        leftTitle: "Accelerations",
                        leftValue: "\(session.accelerationCount ?? 0)",
                        leftColor: .purple,
                        rightTitle: "Decelerations",
                        rightValue: "\(session.decelerationCount ?? 0)",
                        rightColor: .indigo
                    )
                }
                .padding(12)
                .background(summaryContainer, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .padding()
            .padding(.bottom, 20)
        }
        .background(background.ignoresSafeArea())
        .navigationTitle(sessionDateTitle(session.startedAt))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    activeShare = SharePayload(text: sync.shareText(for: session))
                } label: {
                    ZStack {
                        Color.clear
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .frame(width: 32, height: 32, alignment: .center)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func detailRow(
        leftTitle: String,
        leftValue: String,
        leftColor: Color,
        rightTitle: String,
        rightValue: String,
        rightColor: Color
    ) -> some View {
        HStack(spacing: 10) {
            detailMetricColumn(leftTitle, leftValue, color: leftColor)
            detailMetricColumn(rightTitle, rightValue, color: rightColor)
        }
    }

    private func detailMetricColumn(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sessionCard(_ session: BackendSession, showShare: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(normalizeSportName(session.sport))
                    .font(.headline)
                    .foregroundStyle(.white)
                Spacer()
                if showShare {
                    Button {
                        activeShare = SharePayload(text: sync.shareText(for: session))
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(sync.formattedDate(session.startedAt))
                .font(.caption)
                .foregroundStyle(mutedText)

            HStack(spacing: 12) {
                metricChip("Time", sync.formattedDuration(session.durationSec))
                metricChip("Distance", String(format: "%.2f km", session.distanceKm))
                metricChip("Active", "\(Int(session.activeCalories)) cal")
            }
        }
        .padding(12)
        .background(surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func metricChip(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.caption2)
                .foregroundStyle(mutedText)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryMetricPill(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2)
                .foregroundStyle(mutedText)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func sportDetailMetricValue(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.subheadline.weight(.medium))
                .foregroundStyle(mutedText)
            Text(value)
                .font(.title2.weight(.bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sportDetailSheet(_ item: SportCardData) -> some View {
        let sessions = visibleSessions
            .filter { normalizeSportName($0.sport) == item.sport }
            .sorted { parseBackendDate($0.startedAt) > parseBackendDate($1.startedAt) }

        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Session History")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        if !sessions.isEmpty {
                            Button("Clear History") {
                                hiddenSessionIDs.formUnion(sessions.map(\.id))
                                selectedSportDetail = nil
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red.opacity(0.9))
                        }
                    }

                    if sessions.isEmpty {
                        emptyState
                    } else {
                        VStack(spacing: 8) {
                            ForEach(sessions) { session in
                                NavigationLink {
                                    workoutSessionDetailView(session)
                                } label: {
                                    historyRow(session)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(detailContainer.ignoresSafeArea())
            .navigationTitle(item.sport)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { selectedSportDetail = nil }
                }
            }
        }
    }

    private func compareRow(_ label: String, first: String, second: String) -> some View {
        HStack {
            Text(label.uppercased())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(mutedText)
                .frame(width: 72, alignment: .leading)
            Text(first)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(second)
                .font(.title3.weight(.semibold))
                .foregroundStyle(accent)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var profileSheet: some View {
        let pageBackground = detailContainer
        let cardBackground = Color(red: 0.18, green: 0.19, blue: 0.22)

        return ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    Text("Account")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .center)

                    HStack {
                        Button {
                            showingProfile = false
                        } label: {
                            Image(systemName: "xmark")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30, alignment: .center)
                        }
                        .buttonStyle(.plain)

                        Spacer()
                    }
                }
                .padding(.bottom, 8)

                VStack(spacing: 8) {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        profileAvatar(size: 74)
                    }
                    .buttonStyle(.plain)

                    Text("tylerbuchanan2000@gmail.com")
                        .font(.caption)
                        .foregroundStyle(mutedText)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(14)
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                accountSingleRow(title: "Notifications", background: cardBackground)

                VStack(spacing: 0) {
                    accountListRow("Health Details") {
                        showingHealthSheet = true
                    }
                    accountListRow("Change Goals", subtitle: "Coming later")
                    accountListRow("Units of Measure") {
                        showingUnitsSheet = true
                    }
                    accountListRow("Privacy", isLast: true) {
                        showingPrivacySheet = true
                    }
                }
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                Button {
                    auth.signOut()
                    showingProfile = false
                } label: {
                    Text("Sign Out")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.red.opacity(0.95))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.plain)
                .background(cardBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 16)
            .padding(.top, 20)
            .padding(.bottom, 24)
        }
        .background(pageBackground.ignoresSafeArea())
        .sheet(isPresented: $showingUnitsSheet) {
            unitsOfMeasureSheet
        }
        .sheet(isPresented: $showingPrivacySheet) {
            privacyDetailsSheet
        }
        .sheet(isPresented: $showingHealthSheet) {
            healthDetailsSheet
        }
        .preferredColorScheme(.dark)
    }

    private func accountSingleRow(title: String, background: Color) -> some View {
        HStack {
            Text(title)
                .font(.headline.weight(.regular))
                .foregroundStyle(.white)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func accountListRow(
        _ title: String,
        subtitle: String? = nil,
        isLast: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        VStack(spacing: 0) {
            Button {
                action?()
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.headline.weight(.regular))
                            .foregroundStyle(.white)
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if action != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .buttonStyle(.plain)

            if !isLast {
                Divider()
                    .overlay(Color.white.opacity(0.16))
                    .padding(.horizontal, 14)
            }
        }
    }

    private var unitsOfMeasureSheet: some View {
        NavigationStack {
            List {
                Section("UNIT SYSTEM") {
                    Picker("Unit System", selection: $unitSystem) {
                        ForEach(UnitSystem.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("PACE FORMAT") {
                    Picker("Pace", selection: $paceUnit) {
                        ForEach(PaceUnit.allCases, id: \.self) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            .scrollContentBackground(.hidden)
            .background(detailContainer)
            .navigationTitle("Units of Measure")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingUnitsSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private var privacyDetailsSheet: some View {
        NavigationStack {
            List {
                Section("SHARING") {
                    Toggle("Share data with Friends", isOn: $shareWithFriends)
                    Toggle("Share data with EndurOS", isOn: $shareWithAppAnalytics)
                    Toggle("Share for Coach Insights", isOn: $shareForCoachInsights)
                }
            }
            .scrollContentBackground(.hidden)
            .background(detailContainer)
            .navigationTitle("Privacy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingPrivacySheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    private var healthDetailsSheet: some View {
        NavigationStack {
            List {
                Section("TRACKED METRICS") {
                    Toggle("Heart Rate", isOn: $trackHeartRate)
                    Toggle("Location", isOn: $trackLocation)
                    Toggle("Workout Data", isOn: $trackWorkoutData)
                }
            }
            .scrollContentBackground(.hidden)
            .background(detailContainer)
            .navigationTitle("Health Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingHealthSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private func profileAvatar(size: CGFloat) -> some View {
        if let uiImage = UIImage(data: profilePhotoData), !profilePhotoData.isEmpty {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(accent.opacity(0.28))
                .frame(width: size, height: size)
                .overlay(
                    Text(profileInitials.isEmpty ? "?" : String(profileInitials.prefix(3)).uppercased())
                        .font(.system(size: max(12, size * 0.42), weight: .bold))
                        .foregroundStyle(.white)
                )
        }
    }

    @ViewBuilder
    private func profileToolbarAvatar(size: CGFloat) -> some View {
        if let uiImage = UIImage(data: profilePhotoData), !profilePhotoData.isEmpty {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
        } else {
            Text(profileInitials.isEmpty ? "?" : String(profileInitials.prefix(3)).uppercased())
                .font(.system(size: max(13, size * 0.52), weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
        }
    }

    private var visibleSessions: [BackendSession] {
        sync.recentSessions.filter { !hiddenSessionIDs.contains($0.id) }
    }

    private var filteredSessions: [BackendSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return visibleSessions }
        return visibleSessions.filter {
            normalizeSportName($0.sport).lowercased().contains(query)
            || sync.formattedDate($0.startedAt).lowercased().contains(query)
            || String(format: "%.2f", $0.distanceKm).contains(query)
        }
    }

    private var totalDistanceKm: Double {
        visibleSessions.reduce(0) { $0 + $1.distanceKm }
    }

    private var totalActiveCalories: Double {
        visibleSessions.reduce(0) { $0 + $1.activeCalories }
    }

    private var totalSprints: Int {
        visibleSessions.reduce(into: 0) { partialResult, session in
            partialResult += session.sprintCount ?? 0
        }
    }

    private var weeklySessionCount: Int {
        sessionsInLast(days: 7).count
    }

    private var weeklyDistanceKm: Double {
        sessionsInLast(days: 7).reduce(0) { $0 + $1.distanceKm }
    }

    private var weeklyActiveCalories: Double {
        sessionsInLast(days: 7).reduce(0) { $0 + $1.activeCalories }
    }

    private var weeklySprints: Int {
        sessionsInLast(days: 7).reduce(into: 0) { result, session in
            result += session.sprintCount ?? 0
        }
    }

    private var weeklyTopSpeedKmh: Double {
        sessionsInLast(days: 7).map(\.maxSpeedKmh).max() ?? 0
    }


    private var groupedSessionsByMonth: [(month: String, sessions: [BackendSession])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        let grouped = Dictionary(grouping: filteredSessions) { session in
            formatter.string(from: parseBackendDate(session.startedAt))
        }
        return grouped
            .map { key, sessions in
                (
                    month: key,
                    sessions: sessions.sorted { parseBackendDate($0.startedAt) > parseBackendDate($1.startedAt) }
                )
            }
            .sorted {
                let lhsDate = parseBackendDate($0.sessions.first?.startedAt ?? "")
                let rhsDate = parseBackendDate($1.sessions.first?.startedAt ?? "")
                return lhsDate > rhsDate
            }
    }

    private var summarySportOptions: [String] {
        ["All"] + allSports.map(\.name)
    }

    private var summaryFilteredSessions: [BackendSession] {
        guard selectedSummarySportFilter != "All" else { return filteredSessions }
        return filteredSessions.filter {
            normalizeSportName($0.sport) == selectedSummarySportFilter
        }
    }

    private var groupedSummarySessionsByMonth: [(month: String, sessions: [BackendSession])] {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        let grouped = Dictionary(grouping: summaryFilteredSessions) { session in
            formatter.string(from: parseBackendDate(session.startedAt))
        }
        return grouped
            .map { key, sessions in
                (
                    month: key,
                    sessions: sessions.sorted { parseBackendDate($0.startedAt) > parseBackendDate($1.startedAt) }
                )
            }
            .sorted {
                let lhsDate = parseBackendDate($0.sessions.first?.startedAt ?? "")
                let rhsDate = parseBackendDate($1.sessions.first?.startedAt ?? "")
                return lhsDate > rhsDate
            }
    }

    private var sportCards: [SportCardData] {
        let cards = allSports.map { sport in
            let sessions = visibleSessions
                .filter { normalizeSportName($0.sport) == sport.name }
                .sorted { parseBackendDate($0.startedAt) > parseBackendDate($1.startedAt) }
            return SportCardData(
                sport: sport.name,
                icon: sport.icon,
                lastSession: sessions.first
            )
        }
        switch sportsSortMode {
        case .alphabetical:
            return cards.sorted { $0.sport < $1.sport }
        case .mostRecent:
            return cards.sorted { lhs, rhs in
                parseBackendDate(lhs.lastSession?.startedAt ?? "") > parseBackendDate(rhs.lastSession?.startedAt ?? "")
            }
        case .distance:
            return cards.sorted { lhs, rhs in
                (lhs.lastSession?.distanceKm ?? 0) > (rhs.lastSession?.distanceKm ?? 0)
            }
        }
    }

    private var filteredSportCards: [SportCardData] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sportCards }
        return sportCards.filter { card in
            card.sport.lowercased().contains(query)
            || String(format: "%.2f", card.lastSession?.distanceKm ?? 0).contains(query)
        }
    }

    private var visibleSuggestions: [ContactInviteCandidate] {
        contactInviteCandidates.filter { !dismissedSuggestionIDs.contains($0.id) }
    }

    private func refreshContactsState() {
        contactsAuthorization = CNContactStore.authorizationStatus(for: .contacts)
        if contactsAuthorization == .authorized {
            loadContactInviteCandidates()
        }
    }

    private func requestContactsAccess(openInviteAfterGrant: Bool) {
        contactsErrorMessage = nil
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)

        switch status {
        case .authorized:
            contactsAuthorization = .authorized
            loadContactInviteCandidates()
            if openInviteAfterGrant { showingInviteContacts = true }
        case .notDetermined:
            store.requestAccess(for: .contacts) { granted, error in
                Task { @MainActor in
                    if let error {
                        contactsErrorMessage = error.localizedDescription
                    }
                    contactsAuthorization = granted ? .authorized : .denied
                    if granted {
                        loadContactInviteCandidates()
                        if openInviteAfterGrant { showingInviteContacts = true }
                    }
                }
            }
        case .denied, .restricted:
            contactsAuthorization = status
            contactsErrorMessage = "Contacts access denied. Enable it in Settings."
        @unknown default:
            contactsErrorMessage = "Unable to request contacts right now."
        }
    }

    private func openInviteFlow() {
        requestContactsAccess(openInviteAfterGrant: true)
    }

    private func loadContactInviteCandidates() {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)
        var loaded: [ContactInviteCandidate] = []

        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let hasReachableValue = !contact.phoneNumbers.isEmpty || !contact.emailAddresses.isEmpty
                guard hasReachableValue else { return }

                let full = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                guard !full.isEmpty else { return }

                let initials = [contact.givenName.first, contact.familyName.first]
                    .compactMap { $0 }
                    .map { String($0).uppercased() }
                    .joined()

                loaded.append(
                    ContactInviteCandidate(
                        id: contact.identifier,
                        initials: initials.isEmpty ? "?" : initials,
                        name: full
                    )
                )
            }

            contactInviteCandidates = Array(loaded.prefix(20))
            dismissedSuggestionIDs = dismissedSuggestionIDs.intersection(Set(contactInviteCandidates.map(\.id)))
        } catch {
            contactsErrorMessage = error.localizedDescription
        }
    }

    private var filteredInviteCandidates: [ContactInviteCandidate] {
        let query = inviteSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return contactInviteCandidates }
        return contactInviteCandidates.filter {
            $0.name.lowercased().contains(query) || $0.initials.lowercased().contains(query)
        }
    }

    private var inviteContactsSheet: some View {
        NavigationStack {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search contacts", text: $inviteSearchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(filteredInviteCandidates) { contact in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(accent.opacity(0.2))
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Text(contact.initials)
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                    )
                                Text(contact.name)
                                    .font(.body)
                                    .foregroundStyle(.white)
                                Spacer()
                                Button("Invite") {
                                    // TODO: wire backend invite flow.
                                }
                                .font(.subheadline.weight(.semibold))
                            }
                            .padding(10)
                            .background(summaryContainer, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
            }
            .padding()
            .background(detailContainer.ignoresSafeArea())
            .navigationTitle("Invite Friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingInviteContacts = false }
                }
            }
        }
    }

    private var allSports: [SportDefinition] {
        [
            SportDefinition(name: "Field Hockey", icon: "figure.hockey"),
            SportDefinition(name: "Football", icon: "figure.american.football"),
            SportDefinition(name: "Lacrosse", icon: "figure.lacrosse"),
            SportDefinition(name: "Rugby", icon: "figure.rugby"),
            SportDefinition(name: "Running", icon: "figure.run"),
            SportDefinition(name: "Soccer", icon: "figure.soccer")
        ]
    }

    private func iconForNormalizedSport(_ sport: String) -> String {
        allSports.first(where: { $0.name == sport })?.icon ?? "figure.run"
    }

    private func normalizeSportName(_ value: String) -> String {
        let simplified = value
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch simplified {
        case "fieldhockey", "field hockey": return "Field Hockey"
        case "football": return "Football"
        case "lacrosse": return "Lacrosse"
        case "rugby": return "Rugby"
        case "run", "running": return "Running"
        case "soccer": return "Soccer"
        default: return simplified.capitalized
        }
    }

    private func parseBackendDate(_ text: String) -> Date {
        if let date = ISO8601DateFormatter.withFractional.date(from: text) { return date }
        if let date = ISO8601DateFormatter.basic.date(from: text) { return date }
        return .distantPast
    }

    private func sessionsInLast(days: Int) -> [BackendSession] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? .distantPast
        return visibleSessions.filter { parseBackendDate($0.startedAt) >= cutoff }
    }

    private func dayOrDateText(_ iso: String) -> String {
        let date = parseBackendDate(iso)
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    private func sessionTimeRange(_ session: BackendSession) -> String {
        let start = parseBackendDate(session.startedAt)
        let end = parseBackendDate(session.endedAt)
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: start)) - \(formatter.string(from: end))"
    }

    private func sessionDateTitle(_ iso: String) -> String {
        let date = parseBackendDate(iso)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter.string(from: date)
    }

    private func locationName(for session: BackendSession) -> String {
        // Placeholder until reverse geocoding is wired from route samples.
        "Training Field"
    }

    private func formatPace(_ minPerKm: Double?) -> String {
        guard let minPerKm, minPerKm.isFinite, minPerKm > 0 else { return "--" }
        let totalSeconds = Int((minPerKm * 60).rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d /km", minutes, seconds)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No Sessions Yet")
                .font(.headline)
                .foregroundStyle(.white)
            Text("Start and end a watch workout to populate this section.")
                .font(.subheadline)
                .foregroundStyle(mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(summaryContainer, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private enum AppTab {
    case home
    case sports
    case summary
    case sharing
}

private enum SportsSortMode: CaseIterable {
    case mostRecent
    case alphabetical
    case distance

    var label: String {
        switch self {
        case .mostRecent: return "Most Recent"
        case .alphabetical: return "Alphabetical"
        case .distance: return "Distance"
        }
    }

    var shortLabel: String {
        switch self {
        case .mostRecent: return "Recent"
        case .alphabetical: return "A-Z"
        case .distance: return "Distance"
        }
    }
}

private struct SportDefinition {
    let name: String
    let icon: String
}

private struct ContactInviteCandidate: Identifiable {
    let id: String
    let initials: String
    let name: String
}

private struct SportCardData: Identifiable {
    let sport: String
    let icon: String
    let lastSession: BackendSession?

    var id: String { sport }
}

private struct GoalProgress {
    let current: Double
    let goal: Double

    var progress: Double {
        guard goal > 0 else { return 0 }
        return min(1, current / goal)
    }

    static func values(
        sessionsCurrent: Int,
        sessionsGoal: Int,
        distanceCurrent: Double,
        distanceGoal: Double,
        caloriesCurrent: Double,
        caloriesGoal: Double
    ) -> (sessions: (current: Int, goal: Int), distance: GoalProgress, calories: GoalProgress) {
        (
            sessions: (current: sessionsCurrent, goal: sessionsGoal),
            distance: GoalProgress(current: distanceCurrent, goal: distanceGoal),
            calories: GoalProgress(current: caloriesCurrent, goal: caloriesGoal)
        )
    }
}

private struct SharePayload: Identifiable {
    let id = UUID()
    let text: String
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private extension ISO8601DateFormatter {
    static let withFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let basic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

#Preview {
    ContentView()
        .environmentObject(PhoneSyncManager())
        .environmentObject(AuthSessionManager())
}
