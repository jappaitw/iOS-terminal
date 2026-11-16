import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Citadel
import os

private let forwardLog = Logger(subsystem: "com.jlmxstudio.pocketcode", category: "forward")

/// SSH local port forwarding: listens on 127.0.0.1:<localPort> on the phone and tunnels
/// each connection to <remoteHost>:<remotePort> as seen from the SSH server
/// (a `direct-tcpip` channel, like `ssh -L`).
///
/// Used for OAuth flows of CLIs running on the host (e.g. `codex login`), whose sign-in
/// page redirects to http://localhost:<port>/callback — a server on the *host*. With the
/// forward in place, the phone's browser reaches that server.
///
/// The listener runs on the SSH client's own event loop, so both halves of every
/// connection live on one loop and the glue handlers never cross threads.
final class LocalPortForward: @unchecked Sendable {
    let localPort: Int
    private let server: Channel

    private init(localPort: Int, server: Channel) {
        self.localPort = localPort
        self.server = server
    }

    static func start(client: SSHClient, localPort: Int, remoteHost: String = "localhost", remotePort: Int) async throws -> LocalPortForward {
        let bootstrap = ServerBootstrap(group: client.eventLoop)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { local in
                let (localGlue, remoteGlue) = GlueHandler.matchedPair()
                return local.pipeline.addHandler(localGlue).flatMap {
                    let promise = local.eventLoop.makePromise(of: Void.self)
                    promise.completeWithTask {
                        let origin = local.remoteAddress ?? (try! SocketAddress(ipAddress: "127.0.0.1", port: 0))
                        _ = try await client.createDirectTCPIPChannel(
                            using: .init(targetHost: remoteHost, targetPort: remotePort, originatorAddress: origin)
                        ) { ssh in
                            ssh.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).flatMap {
                                ssh.pipeline.addHandler(remoteGlue)
                            }
                        }
                    }
                    promise.futureResult.whenFailure { error in
                        forwardLog.error("forward to \(remoteHost, privacy: .public):\(remotePort) failed: \(String(describing: error), privacy: .public)")
                        local.close(promise: nil)
                    }
                    return promise.futureResult
                }
            }
        let server = try await bootstrap.bind(host: "127.0.0.1", port: localPort).get()
        forwardLog.info("forwarding 127.0.0.1:\(localPort) → \(remoteHost, privacy: .public):\(remotePort)")
        return LocalPortForward(localPort: localPort, server: server)
    }

    func stop() {
        server.close(promise: nil)
        forwardLog.info("stopped forwarding :\(self.localPort)")
    }
}

/// Pipes bytes between two channels with backpressure (the classic SwiftNIO "glue"
/// pattern). Both channels must share an event loop.
final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let a = GlueHandler(), b = GlueHandler()
        a.partner = b
        b.partner = a
        return (a, b)
    }

    // Partner-facing API
    private func partnerWrite(_ data: ByteBuffer) { context?.write(wrapOutboundOut(data), promise: nil) }
    private func partnerFlush() { context?.flush() }
    private func partnerWriteEOF() { context?.close(mode: .output, promise: nil) }
    private func partnerCloseFull() { context?.close(promise: nil) }
    private var partnerIsWritable: Bool { context?.channel.isWritable ?? false }
    private func partnerBecameWritable() {
        if pendingRead {
            pendingRead = false
            context?.read()
        }
    }

    // Channel events
    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        // The other side may have been holding reads until we existed.
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.partnerWrite(unwrapInboundIn(data))
    }

    func channelReadComplete(context: ChannelHandlerContext) { partner?.partnerFlush() }

    func channelInactive(context: ChannelHandlerContext) { partner?.partnerCloseFull() }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            partner?.partnerWriteEOF()
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func read(context: ChannelHandlerContext) {
        if partner?.partnerIsWritable == true {
            context.read()
        } else {
            pendingRead = true
        }
    }
}

/// Recognises OAuth links whose redirect goes back to a server on the SSH host.
enum OAuthRedirect {
    /// The port of a `redirect_uri` pointing at localhost / 127.0.0.1 / [::1], if any.
    static func localCallbackPort(in link: String) -> Int? {
        guard let comps = URLComponents(string: link),
              let redirect = comps.queryItems?.first(where: { $0.name == "redirect_uri" })?.value,
              let r = URLComponents(string: redirect),
              r.scheme?.lowercased() == "http",
              let host = r.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        else { return nil }
        return r.port ?? 80
    }
}
