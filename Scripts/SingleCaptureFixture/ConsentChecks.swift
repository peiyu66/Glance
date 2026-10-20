import Foundation

@MainActor private final class ConsentMemory {
    var value = DataConsent()
    var fails = false
    func controller() -> DataConsentController {
        .init(load: { self.value }, save: { if self.fails { throw CocoaError(.fileWriteOutOfSpace) }; self.value = $0 })
    }
}
@MainActor private func signedIn(_ account: SIWCController) {
    let tokens = SIWCTokens(access: "synthetic", refresh: nil, idToken: "synthetic", scope: SIWCProtocol.scopes, expiresAt: Date().addingTimeInterval(3600))
    let value = SIWCAccount(clientID: "fixture", subject: "fixture", email: "fixture@example.invalid", tokens: tokens)
    account.saved = SIWCSaved(hostID: "fixture", accounts: [value], selected: value.id); account.selectedID = value.id
}

extension C2FixtureHost {
    func runConsentChecks() async -> [String: Bool] {
        var c: [String: Bool] = [:]
        let memory = ConsentMemory(), consent = memory.controller()
        var logins = 0
        let account = SIWCController(beginSignIn: { logins += 1 }, allowsDataTransfer: { consent.allowsTransfer }, authSaveSession: { _ in }, authLoadSession: { nil })
        let host = C2FixtureHost(name: "consent-lifecycle")
        try? FileManager.default.removeItem(at: host.root)
        host.model = host.makeModel(consent: consent, account: account, access: { account.planAccessReady })
        await host.model.bootstrap()
        c["initial_no_camera_or_login"] = host.starts == 0 && logins == 0 && host.model.showingOnboarding
        c["initial_camera_and_photo_closed"] = !host.model.canStartRecognition && host.model.beginPhotoSelection() == nil
        account.beginNewAccount(); c["auth_boundary_requires_consent"] = logins == 0
        host.model.deferSetup(); host.model.foreground(.background); host.model.foreground(.active); await Task.yield()
        c["defer_keeps_local_history_no_login"] = host.model.historyReady && !host.model.showingOnboarding && logins == 0
        host.model.acceptDataUse()
        c["accept_stored_before_one_login"] = memory.value.allowsTransfer && !memory.value.setupCompleted && logins == 1
        c["consent_without_login_still_no_image"] = !host.model.canRecognize && host.calls == 0
        account.cancel(); host.model.foreground(.background); host.model.foreground(.active); await Task.yield()
        c["cancel_no_foreground_login_loop"] = logins == 1
        let reloaded = memory.controller()
        let reopened = host.makeModel(consent: reloaded, account: account, access: { account.planAccessReady })
        await reopened.bootstrap()
        c["cold_reopen_does_not_retry_login"] = logins == 1 && reopened.showingOnboarding && !reloaded.record.setupCompleted
        account.beginNewAccount(); c["explicit_retry_starts_once"] = logins == 2
        signedIn(account); host.model.accountStateChanged()
        c["successful_login_finishes_setup"] = memory.value.setupCompleted && host.model.canRecognize && !host.model.showingOnboarding
        await host.model.openPreview()
        c["login_does_not_start_recognition"] = host.model.previewOpen && !host.model.acquiring && host.calls == 0
        account.signOut(); await host.settle { !account.busy }; host.model.accountStateChanged()
        c["signout_keeps_consent_closes_recognition"] = consent.allowsTransfer && !host.model.canRecognize && !memory.value.setupCompleted
        account.beginNewAccount(); signedIn(account); host.model.accountStateChanged()
        c["explicit_account_switch_supported"] = logins == 3 && host.model.canRecognize
        let upgrade = ConsentMemory(), upgradeConsent = upgrade.controller()
        let upgrading = host.makeModel(consent: upgradeConsent, account: account, access: { account.planAccessReady })
        await upgrading.bootstrap()
        c["existing_login_requires_new_consent"] = upgrading.showingOnboarding && !upgrading.canRecognize
        upgrading.acceptDataUse()
        c["existing_login_does_not_reauthenticate"] = logins == 3 && upgrading.canRecognize && upgrade.value.setupCompleted
        await host.model.openPreview(); _ = host.model.beginAcquisition(); host.feed()
        await host.settle { host.waiter != nil }
        let id = host.model.records.first?.id
        host.model.withdrawDataUse()
        await host.settle { !host.model.busy }
        host.waiter?.resume(returning: C37CandidateProbe.result()); host.waiter = nil
        await Task.yield(); await host.model.waitForCurrentWork()
        c["withdraw_late_ai_not_saved"] = host.model.records.first?.result == nil && host.model.records.first?.status != .pending
        c["withdraw_camera_and_photo_closed"] = !host.model.previewOpen && !host.model.canRecognize && host.model.beginPhotoSelection() == nil
        c["withdraw_persists_after_reload"] = !memory.controller().allowsTransfer
        c["withdraw_blocks_retry"] = host.model.records.first.map { !host.model.canRetryImage($0) } == true
        c["withdraw_keeps_local_image"] = if let record = host.model.records.first { await host.model.image(for: record) != nil } else { false }
        if let id { c["withdraw_keeps_delete_available"] = await host.model.deleteRecord(id: id) && host.model.records.isEmpty }
        else { c["withdraw_keeps_delete_available"] = false }
        let callsBeforeSettings = host.calls, loginsBeforeSettings = logins
        host.model.settingsChanged(true)
        for round in 1...3 {
            host.model.acceptDataUse()
            c["settings_reaccept_\(round)_persists"] = consent.allowsTransfer && memory.controller().allowsTransfer && host.model.canRecognize
            c["settings_reaccept_\(round)_stays_in_settings"] = host.model.showingSettings && !host.model.showingOnboarding && !host.model.previewOpen
            host.model.withdrawDataUse()
            c["settings_withdraw_\(round)_persists"] = !consent.allowsTransfer && !memory.controller().allowsTransfer && !host.model.canRecognize
        }
        host.model.settingsChanged(false); await Task.yield()
        c["settings_defer_preserves_withdrawal"] = !consent.allowsTransfer && !host.model.previewOpen
        c["settings_cycles_no_login_or_image_request"] = logins == loginsBeforeSettings && host.calls == callsBeforeSettings
        let failed = ConsentMemory(); failed.fails = true
        let failedConsent = failed.controller()
        c["failed_persistence_cannot_enable_transfer"] = !failedConsent.accept(accountReady: true) && !failedConsent.allowsTransfer
        c["corrupt_storage_fails_closed"] = !DataConsentController(load: { throw CocoaError(.fileReadCorruptFile) }, save: { _ in }).allowsTransfer
        // The account provider itself rejects direct legacy-camera calls before any mock transport.
        do { _ = try await account.recognize(jpeg: Self.jpeg(.blue)); c["direct_account_image_boundary"] = false }
        catch { c["direct_account_image_boundary"] = true }
        host.model.closePreview(); reopened.closePreview(); upgrading.closePreview()
        return c
    }
}

@MainActor extension DataConsentController {
    static func fixtureAccepted() -> DataConsentController {
        var state = DataConsent(); state.accept(accountReady: true)
        return .init(load: { state }, save: { _ in })
    }
}

@MainActor extension C2FixtureHost {
    func configureOnboardingFixture() {
        let key = "c37.fixture.consent"
        if !ProcessInfo.processInfo.arguments.contains("--resume-consent") { UserDefaults.standard.removeObject(forKey: key) }
        let consent = DataConsentController(load: {
            guard let data = UserDefaults.standard.data(forKey: key) else { return DataConsent() }
            return try JSONDecoder().decode(DataConsent.self, from: data)
        }, save: {
            if ProcessInfo.processInfo.arguments.contains("--fail-consent-save") { throw CocoaError(.fileWriteOutOfSpace) }
            UserDefaults.standard.set(try JSONEncoder().encode($0), forKey: key)
        })
        let account = SIWCController(beginSignIn: { [weak self] in
            guard let self else { return }; self.loginCalls += 1
            if !ProcessInfo.processInfo.arguments.contains("--cancel-mock-login") {
                signedIn(self.model.account); self.model.accountStateChanged()
            }
        }, allowsDataTransfer: { consent.allowsTransfer }, authSaveSession: { _ in }, authLoadSession: { nil })
        if ProcessInfo.processInfo.arguments.contains("--existing-login") { signedIn(account) }
        model = makeModel(consent: consent, account: account, access: { account.planAccessReady })
    }
}
