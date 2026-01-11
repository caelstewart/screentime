//
//  AuthenticationManager.swift
//  screentime-workout
//
//  Created by Cael Stewart on 2025-12-30.
//

import Foundation
import FirebaseCore
import FirebaseAuth
import AuthenticationServices
import CryptoKit
import UIKit
import GoogleSignIn

@Observable
final class AuthenticationManager: NSObject {
    static let shared = AuthenticationManager()
    
    private(set) var user: User?
    private(set) var isAuthenticated = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    
    // For Apple Sign In
    private var currentNonce: String?
    
    // For account linking
    private var anonymousUserId: String?
    
    // Track if we've set up the auth listener
    private var hasAuthListener = false
    
    private override init() {
        super.init()
        
        // Only set up auth listener if Firebase is configured
        // During onboarding, Firebase is not configured - we'll set it up later
        setupAuthListenerIfNeeded()
    }
    
    /// Set up Firebase Auth listener (safe to call multiple times)
    func setupAuthListenerIfNeeded() {
        guard !hasAuthListener else { return }
        
        // Check if Firebase is configured
        guard FirebaseApp.app() != nil else {
            print("[Auth] Firebase not configured yet - will set up listener later")
            return
        }
        
        hasAuthListener = true
        print("[Auth] Setting up auth state listener")
        
        // Listen for auth state changes
        Auth.auth().addStateDidChangeListener { [weak self] _, user in
            DispatchQueue.main.async {
                self?.user = user
                self?.isAuthenticated = user != nil
                print("[Auth] State changed - authenticated: \(user != nil), anonymous: \(user?.isAnonymous ?? false)")
            }
        }
    }
    
    var displayName: String {
        if user?.isAnonymous == true {
            // Get name from UserDefaults for anonymous users
            return UserDefaults.standard.string(forKey: "onboarding_user_name") ?? "User"
        }
        return user?.displayName ?? user?.email ?? "User"
    }
    
    var email: String {
        user?.email ?? ""
    }
    
    var photoURL: URL? {
        user?.photoURL
    }
    
    var isAnonymous: Bool {
        user?.isAnonymous ?? false
    }
    
    func clearError() {
        errorMessage = nil
    }
    
    // MARK: - Anonymous Authentication
    
    /// Signs in anonymously. Use this when user skips login.
    /// Data will be preserved if they later sign up with Apple/Google.
    @MainActor
    func signInAnonymously() async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        do {
            let result = try await Auth.auth().signInAnonymously()
            print("[Auth] Anonymous sign in successful: \(result.user.uid)")
        } catch {
            errorMessage = error.localizedDescription
            print("[Auth] Anonymous sign in error: \(error)")
            throw error
        }
    }
    
    // MARK: - Google Sign In
    
    @MainActor
    func signInWithGoogle() async throws {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        // Store anonymous user ID for potential linking
        let wasAnonymous = user?.isAnonymous ?? false
        let previousAnonymousId = wasAnonymous ? user?.uid : nil
        
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            errorMessage = "Missing Firebase client ID"
            throw AuthError.missingClientID
        }
        
        let config = GIDConfiguration(clientID: clientID)
        GIDSignIn.sharedInstance.configuration = config
        
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let rootViewController = windowScene.windows.first?.rootViewController else {
            errorMessage = "Unable to find root view controller"
            throw AuthError.noRootViewController
        }
        
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController)
            
            guard let idToken = result.user.idToken?.tokenString else {
                errorMessage = "Missing ID token from Google"
                throw AuthError.missingIDToken
            }
            
            let credential = GoogleAuthProvider.credential(
                withIDToken: idToken,
                accessToken: result.user.accessToken.tokenString
            )
            
            // If user was anonymous, link the account instead of signing in fresh
            if wasAnonymous, let currentUser = Auth.auth().currentUser {
                do {
                    let authResult = try await currentUser.link(with: credential)
                    print("[Auth] Linked Google account to anonymous: \(authResult.user.email ?? "no email")")
                } catch let linkError as NSError where linkError.code == AuthErrorCode.credentialAlreadyInUse.rawValue {
                    // Account already exists, sign in and merge data
                    print("[Auth] Google account already exists, signing in and merging data")
                    let authResult = try await Auth.auth().signIn(with: credential)
                    
                    // Merge anonymous data to the existing account
                    if let anonId = previousAnonymousId {
                        await UserDataManager.shared.mergeAnonymousData(fromAnonymousId: anonId, toRealId: authResult.user.uid)
                    }
                }
            } else {
                let authResult = try await Auth.auth().signIn(with: credential)
                print("[Auth] Google sign in successful: \(authResult.user.email ?? "no email")")
            }
            
        } catch let error as GIDSignInError where error.code == .canceled {
            // User cancelled - don't show error
            print("[Auth] Google sign in cancelled by user")
        } catch {
            errorMessage = error.localizedDescription
            print("[Auth] Google sign in error: \(error)")
            throw error
        }
    }
    
    /// Handle URL callback for Google Sign-In
    func handleURL(_ url: URL) -> Bool {
        return GIDSignIn.sharedInstance.handle(url)
    }
    
    // MARK: - Apple Sign In
    
    func handleAppleSignInRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = randomNonceString()
        currentNonce = nonce
        // Store anonymous user ID for potential linking
        if user?.isAnonymous == true {
            anonymousUserId = user?.uid
        }
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
    }
    
    @MainActor
    func handleAppleSignInCompletion(_ result: Result<ASAuthorization, Error>) async {
        isLoading = true
        errorMessage = nil
        
        defer { isLoading = false }
        
        let wasAnonymous = user?.isAnonymous ?? false
        let previousAnonymousId = anonymousUserId
        
        switch result {
        case .success(let authorization):
            guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let appleIDToken = appleIDCredential.identityToken,
                  let idTokenString = String(data: appleIDToken, encoding: .utf8),
                  let nonce = currentNonce else {
                errorMessage = "Unable to fetch Apple ID credentials"
                return
            }
            
            let credential = OAuthProvider.appleCredential(
                withIDToken: idTokenString,
                rawNonce: nonce,
                fullName: appleIDCredential.fullName
            )
            
            do {
                // If user was anonymous, link the account instead of signing in fresh
                if wasAnonymous, let currentUser = Auth.auth().currentUser {
                    do {
                        let authResult = try await currentUser.link(with: credential)
                        print("[Auth] Linked Apple account to anonymous: \(authResult.user.email ?? "no email")")
                    } catch let linkError as NSError where linkError.code == AuthErrorCode.credentialAlreadyInUse.rawValue {
                        // Account already exists, sign in and merge data
                        print("[Auth] Apple account already exists, signing in and merging data")
                        let authResult = try await Auth.auth().signIn(with: credential)
                        
                        // Merge anonymous data to the existing account
                        if let anonId = previousAnonymousId {
                            await UserDataManager.shared.mergeAnonymousData(fromAnonymousId: anonId, toRealId: authResult.user.uid)
                        }
                    }
                } else {
                    let authResult = try await Auth.auth().signIn(with: credential)
                    print("[Auth] Apple sign in successful: \(authResult.user.email ?? "no email")")
                }
            } catch {
                errorMessage = error.localizedDescription
                print("[Auth] Apple sign in error: \(error)")
            }
            
            // Clear the stored anonymous ID
            anonymousUserId = nil
            
        case .failure(let error):
            // Don't show error if user cancelled
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                errorMessage = error.localizedDescription
            }
            print("[Auth] Apple sign in failed: \(error)")
            anonymousUserId = nil
        }
    }
    
    // MARK: - Sign Out
    
    func signOut() {
        do {
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
            print("[Auth] Signed out successfully")
        } catch {
            errorMessage = error.localizedDescription
            print("[Auth] Sign out error: \(error)")
        }
    }
    
    // MARK: - Delete Account (Required by Apple for App Store)
    
    /// Deletes the user's account. For Apple Sign-In users, this also revokes their token.
    /// Apple requires apps that support account creation to also support account deletion.
    @MainActor
    func deleteAccount() async throws {
        guard let user = Auth.auth().currentUser else {
            throw AuthError.noCurrentUser
        }
        
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        do {
            // Delete the user from Firebase
            try await user.delete()
            print("[Auth] Account deleted successfully")
        } catch {
            // If the error is due to requiring recent login, the user needs to re-authenticate
            errorMessage = error.localizedDescription
            print("[Auth] Account deletion error: \(error)")
            throw error
        }
    }
    
    /// Re-authenticate with Apple before sensitive operations (like account deletion)
    /// This is needed if the user's last sign-in was too long ago
    func startReauthenticationWithApple() -> (nonce: String, request: ASAuthorizationAppleIDRequest) {
        let nonce = randomNonceString()
        currentNonce = nonce
        
        let appleIDProvider = ASAuthorizationAppleIDProvider()
        let request = appleIDProvider.createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = sha256(nonce)
        
        return (nonce, request)
    }
    
    @MainActor
    func reauthenticateWithApple(authorization: ASAuthorization) async throws {
        guard let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let appleIDToken = appleIDCredential.identityToken,
              let idTokenString = String(data: appleIDToken, encoding: .utf8),
              let nonce = currentNonce else {
            throw AuthError.missingIDToken
        }
        
        let credential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: nonce,
            fullName: appleIDCredential.fullName
        )
        
        try await Auth.auth().currentUser?.reauthenticate(with: credential)
        
        // For Apple Sign-In, we should also revoke the token
        if let authCode = appleIDCredential.authorizationCode,
           let authCodeString = String(data: authCode, encoding: .utf8) {
            try await Auth.auth().revokeToken(withAuthorizationCode: authCodeString)
            print("[Auth] Apple token revoked")
        }
    }
    
    // MARK: - Helpers
    
    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if errorCode != errSecSuccess {
            fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(errorCode)")
        }
        
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        let nonce = randomBytes.map { byte in
            charset[Int(byte) % charset.count]
        }
        return String(nonce)
    }
    
    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        let hashString = hashedData.compactMap {
            String(format: "%02x", $0)
        }.joined()
        return hashString
    }
}

// MARK: - Auth Errors

enum AuthError: LocalizedError {
    case missingClientID
    case noRootViewController
    case missingIDToken
    case noCurrentUser
    
    var errorDescription: String? {
        switch self {
        case .missingClientID:
            return "Missing Firebase client ID"
        case .noRootViewController:
            return "Unable to find root view controller"
        case .missingIDToken:
            return "Missing ID token"
        case .noCurrentUser:
            return "No user is currently signed in"
        }
    }
}
