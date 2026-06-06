import SwiftUI
import Combine

/// tvOS sign-in for a Stremio account. Pulls the user's addons (AIOStreams etc.) so their
/// real debrid streams play. The token/addon URLs stay on-device.
struct LoginView: View {
    @ObservedObject var account: StremioAccount
    @EnvironmentObject private var core: CoreBridge
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 28) {
                HStack(spacing: 16) {
                    Image(systemName: "play.tv.fill").font(.system(size: 44)).foregroundStyle(.cyan)
                    Text("StremioX").font(.system(size: 56, weight: .heavy))
                }
                Text("Sign in to your Stremio account to load your addons and streams.")
                    .foregroundStyle(.secondary)

                VStack(spacing: 18) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                }
                .frame(width: 700)

                if let err = account.signInError {
                    Text(err).foregroundStyle(.red)
                }

                Button {
                    busy = true
                    Task { await account.signIn(email: email, password: password); busy = false }
                } label: {
                    Text(busy ? "Signing in…" : "Sign In").frame(width: 300)
                }
                .disabled(busy || email.isEmpty || password.isEmpty)
            }
            .padding(60)
        }
        // Login is pushed via NavigationLink; pop back to Home the moment the token is saved,
        // otherwise a successful sign-in leaves the user staring at this same screen.
        .onReceive(account.$isSignedIn) { signedIn in
            if signedIn {
                core.signedInWithLegacyAuthKey()   // seed the engine now, not on next launch
                dismiss()
            }
        }
    }
}
