import SwiftUI
import AuthenticationServices
import Combine

@MainActor
final class AuthSessionManager: NSObject, ObservableObject {
    enum AppleMode {
        case login
        case createAccount
    }

    struct UserProfile {
        let userID: String
        let displayName: String
        let email: String
    }

    @Published private(set) var isSignedIn = false
    @Published private(set) var profile: UserProfile?
    @Published private(set) var isAuthenticating = false
    @Published var authErrorMessage: String?
    @Published var authNoticeMessage: String?

    @AppStorage("auth_apple_user_id_v1") private var storedUserID: String = ""
    @AppStorage("auth_display_name_v1") private var storedDisplayName: String = ""
    @AppStorage("auth_email_v1") private var storedEmail: String = ""
    @AppStorage("auth_access_token_v1") private var accessToken: String = ""
    @AppStorage("auth_refresh_token_v1") private var refreshToken: String = ""
    @AppStorage("auth_backend_base_url_v1") private var backendBaseURL: String = "http://localhost:4000/api"

    override init() {
        super.init()
        restorePersistedSession()
    }

    func signOut() {
        storedUserID = ""
        storedDisplayName = ""
        storedEmail = ""
        accessToken = ""
        refreshToken = ""
        profile = nil
        isSignedIn = false
        authErrorMessage = nil
        authNoticeMessage = nil
    }

    func requestedScopes(for mode: AppleMode) -> [ASAuthorization.Scope] {
        switch mode {
        case .createAccount:
            return [.fullName, .email]
        case .login:
            return []
        }
    }

    func handleAuthorizationResult(_ result: Result<ASAuthorization, Error>) {
        authNoticeMessage = nil
        switch result {
        case .failure(let error):
            authErrorMessage = error.localizedDescription
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                authErrorMessage = "Invalid Apple ID credential."
                return
            }

            let userID = credential.user
            let incomingName = PersonNameComponentsFormatter().string(from: credential.fullName ?? .init())
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = !incomingName.isEmpty ? incomingName : (storedDisplayName.isEmpty ? "Athlete" : storedDisplayName)
            let email = credential.email ?? (storedEmail.isEmpty ? "Private Email" : storedEmail)

            storedUserID = userID
            storedDisplayName = displayName
            storedEmail = email

            profile = UserProfile(userID: userID, displayName: displayName, email: email)
            isSignedIn = true
            authErrorMessage = nil
        }
    }

    func login(email: String, password: String) async {
        authNoticeMessage = nil
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanEmail.isEmpty, !password.isEmpty else {
            authErrorMessage = "Email and password are required."
            return
        }
        await performCredentialRequest(
            path: "/auth/login",
            body: [
                "email": cleanEmail,
                "password": password
            ]
        )
    }

    func createAccount(name: String, email: String, password: String) async {
        authNoticeMessage = nil
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleanName.isEmpty, !cleanEmail.isEmpty, !password.isEmpty else {
            authErrorMessage = "Name, email, and password are required."
            return
        }
        await performRegistrationRequest(name: cleanName, email: cleanEmail, password: password)
    }

    private func performCredentialRequest(path: String, body: [String: Any]) async {
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            guard let url = URL(string: "\(normalizedBackendBaseURL)\(path)") else {
                throw AuthError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let payload = try decoder.decode(AuthSuccessResponse.self, from: data)

            let resolvedToken = payload.accessToken ?? payload.token
            guard let resolvedToken, !resolvedToken.isEmpty else {
                throw AuthError.missingToken
            }

            accessToken = resolvedToken
            refreshToken = payload.refreshToken ?? ""

            let userID = payload.user?.id ?? storedUserID
            let name = payload.user?.name ?? storedDisplayName
            let email = payload.user?.email ?? storedEmail

            storedUserID = userID.isEmpty ? UUID().uuidString : userID
            storedDisplayName = name.isEmpty ? "Athlete" : name
            storedEmail = email

            profile = UserProfile(
                userID: storedUserID,
                displayName: storedDisplayName,
                email: storedEmail.isEmpty ? "Private Email" : storedEmail
            )
            isSignedIn = true
            authErrorMessage = nil
            authNoticeMessage = nil
        } catch {
            authErrorMessage = error.localizedDescription
            authNoticeMessage = nil
        }
    }

    private func performRegistrationRequest(name: String, email: String, password: String) async {
        isAuthenticating = true
        defer { isAuthenticating = false }

        do {
            guard let url = URL(string: "\(normalizedBackendBaseURL)/auth/register") else {
                throw AuthError.invalidURL
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "name": name,
                "email": email,
                "password": password
            ])

            let (data, response) = try await URLSession.shared.data(for: request)
            try validate(response: response, data: data)

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let payload = try decoder.decode(AuthRegistrationResponse.self, from: data)

            if payload.requiresEmailVerification == true {
                authNoticeMessage = payload.message ?? "Verification email sent. Verify your email, then log in."
                authErrorMessage = nil
                isSignedIn = false
                return
            }

            guard let resolvedToken = payload.accessToken ?? payload.token, !resolvedToken.isEmpty else {
                throw AuthError.missingToken
            }

            accessToken = resolvedToken
            refreshToken = payload.refreshToken ?? ""

            let userID = payload.user?.id ?? storedUserID
            let displayName = payload.user?.name ?? storedDisplayName
            let resolvedEmail = payload.user?.email ?? storedEmail

            storedUserID = userID.isEmpty ? UUID().uuidString : userID
            storedDisplayName = displayName.isEmpty ? "Athlete" : displayName
            storedEmail = resolvedEmail

            profile = UserProfile(
                userID: storedUserID,
                displayName: storedDisplayName,
                email: storedEmail.isEmpty ? "Private Email" : storedEmail
            )
            isSignedIn = true
            authErrorMessage = nil
            authNoticeMessage = nil
        } catch {
            authErrorMessage = error.localizedDescription
            authNoticeMessage = nil
        }
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            if let message = try? JSONDecoder().decode(AuthErrorResponse.self, from: data),
               let backendError = message.error,
               !backendError.isEmpty {
                throw AuthError.backend(backendError)
            }
            throw AuthError.httpStatus(http.statusCode)
        }
    }

    private var normalizedBackendBaseURL: String {
        backendBaseURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func restorePersistedSession() {
        let hasAppleIdentity = !storedUserID.isEmpty
        let hasBackendToken = !accessToken.isEmpty
        guard hasAppleIdentity || hasBackendToken else {
            profile = nil
            isSignedIn = false
            authNoticeMessage = nil
            return
        }
        profile = UserProfile(
            userID: storedUserID.isEmpty ? UUID().uuidString : storedUserID,
            displayName: storedDisplayName.isEmpty ? "Athlete" : storedDisplayName,
            email: storedEmail.isEmpty ? "Private Email" : storedEmail
        )
        isSignedIn = true
    }
}

struct AuthEntryView: View {
    @EnvironmentObject private var auth: AuthSessionManager
    @State private var mode: AuthMode = .none
    @State private var fullName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    private let controlHeight: CGFloat = 52

    private enum AuthMode {
        case none
        case login
        case createAccount

        var title: String {
            switch self {
            case .none: return "EndurOS"
            case .login: return "Log In"
            case .createAccount: return "Create Account"
            }
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(mode.title)
                            .font(.system(size: 42, weight: .bold))
                            .foregroundStyle(.white)

                        Text("Sign in to sync sessions, history, and sharing across devices.")
                            .font(.headline)
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(.leading)
                    }
                    .frame(width: min(geo.size.width - 40, 420), alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, max(0, geo.size.height * 0.26))

                    Spacer(minLength: 0)

                    authControls
                }
                .padding(20)
            }
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var authControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if mode != .none {
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        mode = .none
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.bottom, 2)
            }

            Group {
                switch mode {
                case .none:
                    loginSelectorButton
                case .login:
                    emailField
                case .createAccount:
                    nameField
                }
            }
            .frame(height: controlHeight)

            Group {
                switch mode {
                case .none:
                    createSelectorButton
                case .login:
                    passwordField
                case .createAccount:
                    emailField
                }
            }
            .frame(height: controlHeight)

            Group {
                switch mode {
                case .none:
                    appleButton
                case .login:
                    continueButton
                case .createAccount:
                    passwordField
                }
            }
            .frame(height: controlHeight)

            if mode == .createAccount {
                confirmPasswordField
                    .frame(height: controlHeight)

                continueButton
                    .frame(height: controlHeight)
            }

            messageArea
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var messageArea: some View {
        if let message = auth.authErrorMessage, !message.isEmpty {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
        } else if let message = auth.authNoticeMessage, !message.isEmpty {
            Text(message)
                .font(.footnote)
                .foregroundStyle(Color.green)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            EmptyView()
        }
    }

    private var loginSelectorButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                mode = .login
            }
        } label: {
            Text("Log In")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.indigo, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var createSelectorButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                mode = .createAccount
            }
        } label: {
            Text("Create Account")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var continueButton: some View {
        Button {
            Task {
                switch mode {
                case .login:
                    await auth.login(email: email, password: password)
                case .createAccount:
                    guard password == confirmPassword else {
                        auth.authErrorMessage = "Passwords do not match."
                        auth.authNoticeMessage = nil
                        return
                    }
                    if let notice = auth.authNoticeMessage, !notice.isEmpty {
                        await auth.login(email: email, password: password)
                        return
                    }
                    await auth.createAccount(name: fullName, email: email, password: password)
                case .none:
                    break
                }
            }
        } label: {
            if auth.isAuthenticating {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text("Continue")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .buttonStyle(.plain)
        .background(Color.indigo, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .disabled(auth.isAuthenticating)
    }

    private var appleButton: some View {
        SignInWithAppleButton(mode == .createAccount ? .signUp : .signIn) { request in
            request.requestedScopes = auth.requestedScopes(for: mode == .createAccount ? .createAccount : .login)
        } onCompletion: { result in
            auth.handleAuthorizationResult(result)
        }
        .signInWithAppleButtonStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var nameField: some View {
        TextField("Full Name", text: $fullName)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .authFieldStyle()
    }

    private var emailField: some View {
        TextField("Email", text: $email)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .authFieldStyle()
    }

    private var passwordField: some View {
        SecureField("Password", text: $password)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
            .authFieldStyle()
    }

    private var confirmPasswordField: some View {
        SecureField("Confirm Password", text: $confirmPassword)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textContentType(.password)
            .authFieldStyle()
    }
}

private extension View {
    func authFieldStyle() -> some View {
        self
            .font(.body)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct AuthSuccessResponse: Decodable {
    struct AuthUser: Decodable {
        let id: String
        let name: String?
        let email: String?
    }

    let accessToken: String?
    let refreshToken: String?
    let token: String?
    let user: AuthUser?
}

private struct AuthRegistrationResponse: Decodable {
    struct AuthUser: Decodable {
        let id: String
        let name: String?
        let email: String?
    }

    let requiresEmailVerification: Bool?
    let message: String?
    let accessToken: String?
    let refreshToken: String?
    let token: String?
    let user: AuthUser?
}

private struct AuthErrorResponse: Decodable {
    let error: String?
}

private enum AuthError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case missingToken
    case backend(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid auth endpoint URL."
        case .invalidResponse: return "Invalid network response."
        case .httpStatus(let code): return "Authentication failed (\(code))."
        case .missingToken: return "No access token returned by server."
        case .backend(let message): return message
        }
    }
}
