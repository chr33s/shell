//
//  SSHAuthBannerCard.swift
//  shell
//
//  Live state for the native SSH auth-banner card (issue #290).
//
//  `SSH_MSG_USERAUTH_BANNER` can only arrive during the SSH authentication
//  phase (RFC 4252 §5.4). The inline scrollback flush necessarily waits until
//  `.running` (spinner cleanup would wipe earlier writes), which is too late
//  for banners that tell the user how to authenticate — e.g. Tailscale SSH
//  "check" mode sending its re-auth URL. This model mirrors banners into a
//  nonmodal per-pane card the moment they arrive, and tears the card down
//  when the auth phase ends (the buffer's drain/clear both signal `.reset`).
//

import Foundation

/// One sanitized banner message shown in the card, in arrival order.
struct SSHAuthBannerItem: Equatable, Sendable, Identifiable {
    /// Arrival index within the current auth phase.
    let id: Int
    /// Plain text (already through `SSHBanner.plainText`), non-empty.
    let text: String
    /// http/https URLs extracted from `text`, for explicit open/copy actions.
    let urls: [URL]
    /// Host that sent this banner when it is NOT the card's target host
    /// (i.e. a jump hop). Rendered so a jump host's re-auth URL is never
    /// misattributed to the target. Nil for target-host banners.
    let sourceLabel: String?
}

/// Everything the card needs to render for one authentication phase.
struct SSHAuthBannerCardState: Equatable, Sendable {
    /// Label identifying the connection the banners belong to (target host).
    var hostLabel: String
    var items: [SSHAuthBannerItem]
}

/// Sessions that can surface live auth banners for the pane card.
@MainActor protocol SSHAuthBannerCardProviding: AnyObject {
    /// The session's accumulator. Every conformer stores one under this name,
    /// which is what lets the defaults below cover all of them.
    var authBannerCardModel: SSHAuthBannerCardModel { get }

    var authBannerCardState: SSHAuthBannerCardState? { get }

    /// A fresh stream of card-state updates. Each call registers an
    /// independent subscriber; the current value is replayed as the first
    /// element, so late subscribers (a pane observing after banners arrived,
    /// the keyboard-interactive sheet) still see pending banners. The stream
    /// ends when the consuming task is cancelled or the session deallocates.
    func authBannerCardStates() -> AsyncStream<SSHAuthBannerCardState?>

    /// Retires the card at the user's request. A requirement rather than an
    /// extension-only member so LocalShellSession's forwarding override still
    /// dispatches when called through the existential.
    func dismissAuthBannerCard()
}

extension SSHAuthBannerCardProviding {
    var authBannerCardState: SSHAuthBannerCardState? { authBannerCardModel.current }

    func authBannerCardStates() -> AsyncStream<SSHAuthBannerCardState?> {
        authBannerCardModel.states()
    }

    func dismissAuthBannerCard() { authBannerCardModel.clear() }
}

/// Main-actor accumulator each session owns: bridges `AuthBannerBuffer`
/// events (fired on the NIO event loop) to replaying per-subscriber streams.
@MainActor final class SSHAuthBannerCardModel {
    /// How long a banner outlives the end of the auth phase. Long enough to
    /// read a rejection reason and tap Open/Copy on a URL it carries.
    /// Nonisolated so it can serve as a default argument below.
    nonisolated static let autoDismissSeconds: Double = 15

    private(set) var current: SSHAuthBannerCardState?

    private typealias BannerEvent = (hostLabel: String, event: AuthBannerBuffer.Event)

    /// Ordered channel from the buffer observer (any thread) to the
    /// main-actor pump. Continuation yields preserve FIFO order — banners
    /// must aggregate in arrival order, and unstructured `Task { @MainActor }`
    /// hops do not guarantee that.
    private let eventChannel: AsyncStream<BannerEvent>
    private let eventContinuation: AsyncStream<BannerEvent>.Continuation
    private var pumpTask: Task<Void, Never>?

    private var subscribers: [UUID: AsyncStream<SSHAuthBannerCardState?>.Continuation] = [:]
    private var nextID = 0

    /// Countdown that retires a banner left over from a finished auth phase.
    private var autoDismissTask: Task<Void, Never>?

    /// Latched once the auth phase ends with the card still up, and only
    /// unlatched by `clear()`. Banner events reach this actor over an async
    /// channel while the terminal-state transition that arms the countdown is
    /// a direct main-actor call, so a banner sent immediately before the
    /// disconnect — exactly the Tailscale rejection-reason case — routinely
    /// lands *after* the arm. Without the latch that late broadcast would
    /// cancel the countdown and never restart it, stranding the card forever.
    private var autoDismissArmed = false

    /// Interval the latch re-arms with, so a late banner gets a full read.
    private var autoDismissInterval = SSHAuthBannerCardModel.autoDismissSeconds

    init() {
        (eventChannel, eventContinuation) = AsyncStream.makeStream(of: BannerEvent.self)
        pumpTask = Task { [weak self, eventChannel] in
            for await (hostLabel, event) in eventChannel {
                guard let self else { return }
                self.handle(event, hostLabel: hostLabel)
            }
        }
    }

    deinit {
        pumpTask?.cancel()
        autoDismissTask?.cancel()
        eventContinuation.finish()
        for continuation in subscribers.values {
            continuation.finish()
        }
    }

    /// Returns a buffer observer bound to this model, suitable for
    /// `AuthBannerBuffer.setObserver`. Captures only the channel continuation,
    /// so an observer left on a buffer never retains the session.
    nonisolated func makeBufferObserver(
        hostLabel: String
    ) -> @Sendable (AuthBannerBuffer.Event) -> Void {
        { [eventContinuation] event in
            eventContinuation.yield((hostLabel: hostLabel, event: event))
        }
    }

    /// Registers a new subscriber stream; replays the current value first.
    func states() -> AsyncStream<SSHAuthBannerCardState?> {
        let (stream, continuation) = AsyncStream.makeStream(of: SSHAuthBannerCardState?.self)
        let id = UUID()
        continuation.yield(current)
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.subscribers[id] = nil
            }
        }
        return stream
    }

    /// Removes the card immediately (auth ended, session torn down/replaced,
    /// or the user dismissed it).
    func clear() {
        // Explicit unlatch for the case where there is no current state, so
        // broadcast (which also unlatches on nil) never runs.
        autoDismissArmed = false
        autoDismissTask?.cancel()
        autoDismissTask = nil
        if current != nil { broadcast(nil) }
    }

    /// Arms the countdown that retires the current banner once the auth phase
    /// has ended. Safe to call before the banner itself arrives: the latch
    /// re-arms on every later broadcast until something clears the card.
    func scheduleAutoDismiss(after seconds: Double = SSHAuthBannerCardModel.autoDismissSeconds) {
        autoDismissArmed = true
        autoDismissInterval = seconds
        restartAutoDismissTimer()
    }

    private func restartAutoDismissTimer() {
        let seconds = autoDismissInterval
        autoDismissTask?.cancel()
        autoDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.clear()
        }
    }

    /// Directly relays an already-built state. Used by forwarding wrappers
    /// (LocalShellSession) that mirror an embedded session's card state.
    func relay(_ state: SSHAuthBannerCardState?) {
        broadcast(state)
    }

    private func handle(_ event: AuthBannerBuffer.Event, hostLabel: String) {
        switch event {
        case .appended(let raw, let source):
            let text = SSHBanner.plainText(raw)
            guard !text.isEmpty else { return }
            let item = SSHAuthBannerItem(
                id: nextID,
                text: text,
                urls: SSHBanner.extractHTTPURLs(from: text),
                sourceLabel: source
            )
            nextID += 1
            var state = current ?? SSHAuthBannerCardState(hostLabel: hostLabel, items: [])
            state.items.append(item)
            broadcast(state)
        case .reset:
            clear()
        }
    }

    private func broadcast(_ state: SSHAuthBannerCardState?) {
        autoDismissTask?.cancel()
        autoDismissTask = nil
        // A cleared card ends the armed phase. Without this, a retry that
        // replays nil (password fallback re-subscribing to a fresh session)
        // would leave the latch set and put a live auth banner from the *next*
        // attempt on a countdown.
        if state == nil { autoDismissArmed = false }
        current = state
        for continuation in subscribers.values {
            continuation.yield(state)
        }
        // New content restarts the clock rather than cancelling it: while
        // authenticating nothing is armed, so this is a no-op; after the auth
        // phase ended it gives a late-arriving banner a full read window.
        if autoDismissArmed, state != nil { restartAutoDismissTimer() }
    }
}
