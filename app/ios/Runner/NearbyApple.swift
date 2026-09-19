// SPDX-License-Identifier: AGPL-3.0-or-later
import Flutter
import UIKit
import SwiftUI
import CoreBluetooth
import Network
import WiFiAware
import DeviceDiscoveryUI

/// Paired Wi-Fi Aware on supported iOS 26 hardware; common encrypted GATT is
/// independent and remains available on older/unpaired/incompatible phones.
final class NearbyApple: NSObject, FlutterPlugin, FlutterStreamHandler, URLSessionTaskDelegate,
    UIAdaptivePresentationControllerDelegate {
    private var sink: FlutterEventSink?
    private var running = false
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var endpoints = Set<NWEndpoint>()
    private var retry: Timer?
    private var links: [String: Link] = [:]
    private var epoch = 0
    private weak var pairingController: UIViewController?
    private var pairingEpoch: Int?
    private let monitor = NWPathMonitor()
    private var reachable = false
    private var internet = "unknown"
    private var probed = Date.distantPast
    private var probe: URLSessionDataTask?
    private var probeSession: URLSession?
    private var window = Date()
    private var bytes = 0
    private var frames = 0
    private static let maxFrame = 32786
    private static let service = "_hearth-text._tcp"
    private final class Link {
        let connection: NWConnection
        let outgoing: NWEndpoint?
        var timeout: DispatchWorkItem?
        var pending = 0
        var ready = false
        init(_ connection: NWConnection, outgoing: NWEndpoint?) {
            self.connection = connection; self.outgoing = outgoing
        }
    }

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = NearbyApple()
        let method = FlutterMethodChannel(name: "hearth/nearby", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(instance, channel: method)
        FlutterEventChannel(name: "hearth/nearby_events", binaryMessenger: registrar.messenger()).setStreamHandler(instance)
        instance.monitor.pathUpdateHandler = { [weak instance] path in
            DispatchQueue.main.async {
                guard let self = instance else { return }
                self.reachable = path.status == .satisfied
                self.internet = self.reachable ? "unknown" : "offline"
                self.probed = .distantPast
                // A result from the previous network cannot validate this path.
                self.probe?.cancel(); self.probe = nil
                self.probeSession?.invalidateAndCancel(); self.probeSession = nil
            }
        }
        instance.monitor.start(queue: DispatchQueue(label: "hearth.nearby.path"))
    }
    private var awareSupported: Bool {
        if #available(iOS 26.0, *) { return !WACapabilities.supportedFeatures.isEmpty }
        return false
    }
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "capabilities":
            let args = call.arguments as? [String: Any]
            if args?["probe"] as? Bool == true { checkInternet() }
            else { probe?.cancel(); probe = nil; probeSession?.invalidateAndCancel(); probeSession = nil }
            var allowed = true
            if #available(iOS 13.1, *) {
                allowed = CBManager.authorization != .denied && CBManager.authorization != .restricted
            }
            result(["supported": true, "permitted": true, "radioReady": awareSupported || allowed,
                    "wifiReady": awareSupported, "awareSupported": awareSupported,
                    "awarePairing": awareSupported, "bluetoothReady": allowed,
                    "internet": reachable ? internet : "offline", "stopped": false])
        case "rearm", "serviceStart": result(nil)
        case "serviceStop":
            probe?.cancel(); probe = nil; probeSession?.invalidateAndCancel(); probeSession = nil
            result(nil)
        case "start":
            guard awareSupported else {
                result(FlutterError(code: "nearby_aware", message: "Wi-Fi Aware is unavailable", details: nil)); return
            }
            if !running {
                running = true; epoch += 1
                do { if #available(iOS 26.0, *) { try startWiFi() } }
                catch { stopWiFi(); result(FlutterError(code: "nearby_aware", message: "Wi-Fi Aware could not start", details: nil)); return }
            }
            result(nil)
        case "stop": stopWiFi(); result(nil)
        case "pair":
            guard running, awareSupported, pairingEpoch == nil, #available(iOS 26.0, *),
                  let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
                  let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else {
                result(FlutterError(code: "nearby_pair", message: "Enable nearby mode on a Wi-Fi Aware capable device", details: nil)); return
            }
            var presenter = root
            while let presented = presenter.presentedViewController { presenter = presented }
            // DeviceDiscoveryUI owns the service while pairing. Do not publish
            // a second copy of it, or interrupt the independent BLE adapter.
            epoch += 1
            stopTransport()
            pairingEpoch = epoch
            let controller = UIHostingController(rootView: NearbyPairingView(onClose: { [weak self] in
                self?.closePairing()
            }))
            pairingController = controller
            presenter.present(controller, animated: true)
            controller.presentationController?.delegate = self
            result(nil)
        case "disconnect":
            if let id = (call.arguments as? [String: Any])?["id"] as? String { drop(id) }
            result(nil)
        case "send":
            let args = call.arguments as? [String: Any]
            guard let id = args?["id"] as? String, let link = links[id], link.ready,
                  let value = args?["bytes"] as? FlutterStandardTypedData,
                  !value.data.isEmpty, value.data.count <= Self.maxFrame, link.pending < 8 else {
                result(FlutterError(code: "nearby_send", message: "Nearby link unavailable", details: nil)); return
            }
            link.pending += 1
            let count = UInt32(value.data.count)
            var data = Data([UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
            data.append(value.data)
            link.connection.send(content: data, completion: .contentProcessed { [weak self, weak link] error in
                link?.pending -= 1
                if error != nil {
                    self?.drop(id)
                    result(FlutterError(code: "nearby_send", message: "Nearby send failed", details: nil))
                } else { result(nil) }
            })
        default: result(FlutterMethodNotImplemented)
        }
    }
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        sink = events; return nil
    }
    func onCancel(withArguments arguments: Any?) -> FlutterError? { stopWiFi(); sink = nil; return nil }

    @available(iOS 26.0, *)
    private func startWiFi() throws {
        guard let publishing = WAPublishableService.allServices[Self.service],
              let subscribing = WASubscribableService.allServices[Self.service] else {
            throw NSError(domain: "hearth.nearby", code: 1)
        }
        let current = epoch
        let provider: WAPublisherListener = .wifiAware(.connecting(to: publishing, from: .allPairedDevices))
        let parameters = NWParameters.tcp
        provider.configureParameters(parameters)
        parameters.wifiAware = .defaults
        let l = try NWListener(using: parameters)
        l.service = provider.service
        l.newConnectionHandler = { [weak self] connection in
            guard let self = self, self.running, self.epoch == current else { connection.cancel(); return }
            self.add(connection, outgoing: nil)
        }
        l.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.fail(current) }
        }
        listener = l
        l.start(queue: .main)

        let subscription: WASubscriberBrowser = .wifiAware(.connecting(to: .allPairedDevices, from: subscribing))
        let b = NWBrowser(for: subscription.makeDescriptor(), using: subscription.configureParameters(.tcp))
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self, self.running, self.epoch == current else { return }
            self.endpoints = Set(results.prefix(16).map { $0.endpoint })
            self.connectDiscovered()
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.fail(current) }
        }
        browser = b
        b.start(queue: .main)
        retry = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in self?.connectDiscovered() }
    }
    private func connectDiscovered() {
        guard running, #available(iOS 26.0, *),
              let service = WASubscribableService.allServices[Self.service] else { return }
        let subscription: WASubscriberBrowser = .wifiAware(.connecting(to: .allPairedDevices, from: service))
        for endpoint in endpoints {
            if links.count >= 6 { break }
            if links.values.contains(where: { $0.outgoing == endpoint }) { continue }
            let parameters = subscription.configureParameters(.tcp)
            parameters.wifiAware = .defaults
            add(NWConnection(to: endpoint, using: parameters), outgoing: endpoint)
        }
    }
    private func add(_ connection: NWConnection, outgoing: NWEndpoint?) {
        guard running, links.count < 6 else { connection.cancel(); return }
        let id = "aware:" + UUID().uuidString
        let link = Link(connection, outgoing: outgoing)
        links[id] = link
        arm(id, seconds: 20)
        connection.stateUpdateHandler = { [weak self, weak link] state in
            guard let self = self, let link = link, self.links[id] === link else { return }
            switch state {
            case .ready:
                guard !link.ready else { return }
                link.ready = true
                self.sink?(["type": "linkUp", "id": id, "medium": "wifiAware"])
                self.arm(id, seconds: 90)
                self.readHeader(id)
            case .failed, .cancelled: self.drop(id)
            default: break
            }
        }
        connection.start(queue: .main)
    }
    private func arm(_ id: String, seconds: TimeInterval) {
        guard let link = links[id] else { return }
        link.timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.drop(id) }
        link.timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    private func readHeader(_ id: String) {
        guard let link = links[id] else { return }
        link.connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self, weak link] data, _, ended, error in
            guard let self = self, let link = link, self.links[id] === link else { return }
            guard error == nil, !ended, let data = data, data.count == 4 else { self.drop(id); return }
            let size = data.reduce(0) { ($0 << 8) | Int($1) }
            if Date().timeIntervalSince(self.window) >= 60 { self.window = Date(); self.bytes = 0; self.frames = 0 }
            self.bytes += size; self.frames += 1
            guard size > 0, size <= Self.maxFrame, self.bytes <= 2 * 1024 * 1024, self.frames <= 256 else { self.drop(id); return }
            link.connection.receive(minimumIncompleteLength: size, maximumLength: size) { [weak self, weak link] body, _, ended, error in
                guard let self = self, let link = link, self.links[id] === link else { return }
                guard error == nil, let body = body, body.count == size else { self.drop(id); return }
                self.sink?(["type": "bytes", "id": id, "bytes": FlutterStandardTypedData(bytes: body)])
                if ended { self.drop(id) }
                else { self.arm(id, seconds: 90); self.readHeader(id) }
            }
        }
    }
    private func drop(_ id: String) {
        guard let link = links.removeValue(forKey: id) else { return }
        link.timeout?.cancel(); link.connection.cancel()
        sink?(["type": "linkDown", "id": id])
    }
    private func stopWiFi() {
        running = false; epoch += 1
        pairingEpoch = nil
        pairingController?.dismiss(animated: true)
        pairingController = nil
        stopTransport()
    }
    private func stopTransport() {
        retry?.invalidate(); retry = nil
        browser?.cancel(); browser = nil
        listener?.cancel(); listener = nil
        endpoints.removeAll()
        for id in Array(links.keys) { drop(id) }
    }
    private func closePairing() {
        guard let current = pairingEpoch else { return }
        guard let controller = pairingController else { finishPairing(current); return }
        controller.dismiss(animated: true) { [weak self] in self?.finishPairing(current) }
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard presentationController.presentedViewController === pairingController,
              let current = pairingEpoch else { return }
        finishPairing(current)
    }
    private func finishPairing(_ current: Int) {
        guard pairingEpoch == current else { return }
        pairingEpoch = nil; pairingController = nil
        guard running, epoch == current, #available(iOS 26.0, *) else { return }
        do { try startWiFi() } catch { fail(current) }
    }
    private func fail(_ current: Int) {
        guard running, epoch == current else { return }
        stopWiFi()
        sink?(["type": "error", "message": "Wi-Fi Aware unavailable; Bluetooth remains available"])
    }
    /// NWPath reports an interface, not Internet access. Use a bounded HTTPS
    /// probe only while the user has enabled automatic nearby activation.
    private func checkInternet() {
        guard reachable, probe == nil, Date().timeIntervalSince(probed) >= 30 else { return }
        probed = Date()
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4; config.timeoutIntervalForResource = 5
        config.httpCookieStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        probeSession = session
        var request = URLRequest(url: URL(string: "https://connectivitycheck.gstatic.com/generate_204")!)
        request.httpMethod = "HEAD"
        probe = session.dataTask(with: request) { [weak self, weak session] _, response, error in
            DispatchQueue.main.async {
                guard let self = self, self.probeSession === session else { return }
                self.internet = error == nil && (response as? HTTPURLResponse)?.statusCode == 204 ? "online" : "offline"
                self.probe = nil; self.probeSession = nil
                session?.finishTasksAndInvalidate()
            }
        }
        probe?.resume()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@available(iOS 26.0, *)
private struct NearbyPairingView: View {
    let onClose: () -> Void
    var body: some View {
        NavigationStack {
            List {
                if let publisher = WAPublishableService.allServices["_hearth-text._tcp"],
                   let subscriber = WASubscribableService.allServices["_hearth-text._tcp"] {
                    DevicePairingView(.wifiAware(.connecting(to: publisher, from: .userSpecifiedDevices))) {
                        Label("Allow pairing", systemImage: "antenna.radiowaves.left.and.right")
                    } fallback: { Text("Wi-Fi Aware unavailable") }
                    DevicePicker(.wifiAware(.connecting(to: .userSpecifiedDevices, from: subscriber))) { _ in
                    } label: { Label("Find device", systemImage: "magnifyingglass") }
                    fallback: { Text("Wi-Fi Aware unavailable") }
                }
            }
            .navigationTitle("Wi-Fi Aware pairing")
            .toolbar { Button("Done", action: onClose) }
        }
    }
}
