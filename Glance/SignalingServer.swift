import Foundation
import Network

/// Ports and URL helpers for local streaming.
/// The static page is served by the user (`python3 -m http.server 8888 --directory Web`);
/// the API below is served by the app itself for WebRTC signaling.
enum StreamPorts {
  static let page: UInt16 = 8888
  static let api: UInt16 = 8899

  static func pageURL(streamId: String) -> URL {
    URL(string: "http://localhost:\(page)/?stream=\(streamId)")!
  }
}

struct OfferRequest: Decodable {
  var stream: String
  var sdp: String
  var type: String
}

struct StatusSnapshot: Encodable {
  var live: Bool
  var viewers: Int
}

enum OfferResult {
  case answer(sdp: String)
  case noStream
  case failure(String)
}

private let allowedOrigins: Set<String> = [
  "http://localhost:8888",
  "http://127.0.0.1:8888",
]

/// Minimal HTTP/1.1 server on 127.0.0.1 for WebRTC signaling.
/// Handles OPTIONS (CORS preflight), POST /api/offer and GET /api/status.
/// Everything else 404s. Connections are closed after one response.
@MainActor
final class SignalingServer {
  var onOffer: ((OfferRequest) async -> OfferResult)?
  var statusProvider: ((String) -> StatusSnapshot)?
  var onListenError: ((String) -> Void)?
  var onListening: (() -> Void)?

  private var listener: NWListener?
  private let queue = DispatchQueue(label: "glance.signaling")

  func start(port: UInt16 = StreamPorts.api) {
    stop()
    do {
      let params = NWParameters.tcp
      params.requiredLocalEndpoint = NWEndpoint.hostPort(
        host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!)
      // Port comes from requiredLocalEndpoint; passing it to `on:` too makes
      // NWListener refuse to start.
      listener = try NWListener(using: params)
    } catch {
      NSLog("[Glance] signaling failed to listen: %@", error.localizedDescription as NSString)
      return
    }
    listener?.newConnectionHandler = { [weak self] connection in
      Task { @MainActor in self?.handle(connection) }
    }
    listener?.stateUpdateHandler = { [weak self] state in
      Task { @MainActor in self?.handleListenerState(state, port: port) }
    }
    listener?.start(queue: queue)
    NSLog("[Glance] signaling starting on 127.0.0.1:%d", Int(port))
  }

  private func handleListenerState(_ state: NWListener.State, port: UInt16) {
    switch state {
    case .ready:
      NSLog("[Glance] signaling listening on 127.0.0.1:%d", Int(port))
      onListening?()
    case .failed(let error):
      NSLog("[Glance] signaling failed: %@", error.localizedDescription as NSString)
      onListenError?("Port \(port) unavailable (\(error.localizedDescription)).")
    case .waiting(let error):
      // Bind conflicts (e.g. another Glance still running) land here.
      NSLog("[Glance] signaling waiting: %@", error.localizedDescription as NSString)
      onListenError?("Port \(port) unavailable (\(error.localizedDescription)).")
    default:
      break
    }
  }

  func stop() {
    listener?.cancel()
    listener = nil
  }

  // MARK: - Connections

  private func handle(_ connection: NWConnection) {
    connection.start(queue: queue)
    readHeaders(connection, accumulated: Data()) { [weak self] headerData, remainder in
      Task { @MainActor in
        self?.route(connection, headerData: headerData, remainder: remainder)
      }
    }
  }

  private func readHeaders(
    _ connection: NWConnection, accumulated: Data,
    completion: @escaping (Data, Data) -> Void
  ) {
    var acc = accumulated
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
      if let data, !data.isEmpty { acc.append(data) }
      if let range = acc.range(of: Data("\r\n\r\n".utf8)) {
        let end = range.upperBound
        completion(acc.prefix(upTo: end), acc.suffix(from: end))
        return
      }
      if error != nil || acc.count > 65536 {
        connection.cancel()
        return
      }
      self.readHeaders(connection, accumulated: acc, completion: completion)
    }
  }

  private func readBody(
    _ connection: NWConnection, remainder: Data, length: Int,
    completion: @escaping (Data) -> Void
  ) {
    var acc = remainder
    if acc.count >= length {
      completion(acc.prefix(length))
      return
    }
    connection.receive(minimumIncompleteLength: 1, maximumLength: length - acc.count) {
      data, _, _, _ in
      if let data { acc.append(data) }
      if acc.count >= length {
        completion(acc.prefix(length))
      } else {
        self.readBody(connection, remainder: acc, length: length, completion: completion)
      }
    }
  }

  // MARK: - Routing (MainActor)

  private func route(_ connection: NWConnection, headerData: Data, remainder: Data) {
    guard let head = String(data: headerData, encoding: .utf8) else {
      // Too malformed to have parsed headers: no CORS grant by definition.
      send(connection, status: 400, json: ["error": "bad request"], origin: nil)
      return
    }
    let lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.first?.components(separatedBy: " ") ?? []
    guard requestLine.count >= 2 else {
      send(connection, status: 400, json: ["error": "bad request"], origin: nil)
      return
    }
    let method = requestLine[0].uppercased()
    let target = requestLine[1]
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      let parts = line.split(separator: ":", maxSplits: 1).map {
        $0.trimmingCharacters(in: .whitespaces)
      }
      if parts.count == 2 { headers[parts[0].lowercased()] = parts[1] }
    }
    let origin = headers["origin"] ?? ""
    let originOk = allowedOrigins.contains(origin)

    // Preflight: only bless origins we'd actually accept, and tell the browser
    // so a blocked page fails fast with a readable error.
    if method == "OPTIONS" {
      send(
        connection, status: 204, json: Optional<[String: String]>.none,
        origin: originOk ? origin : nil)
      return
    }

    if method == "GET", target == "/api/ping" || target.hasPrefix("/api/ping?") {
      // Unauthenticated on purpose: reveals nothing and is handy from a terminal.
      send(connection, status: 200, json: ["ok": "true"], origin: originOk ? origin : nil)
      return
    }

    // Everything past here is introspection or screen access: require a trusted origin.
    if !originOk {
      NSLog("[Glance] rejected request to %@ from unexpected origin %@", target, origin)
      send(
        connection, status: 403,
        json: ["error": "origin not allowed — serve the page from http://localhost:8888"],
        origin: nil)
      return
    }

    if method == "GET", target.hasPrefix("/api/status") {
      let id = queryParam(target, name: "stream") ?? ""
      let snapshot = statusProvider?(id) ?? StatusSnapshot(live: false, viewers: 0)
      send(connection, status: 200, json: snapshot, origin: origin)
      return
    }

    if method == "POST", target == "/api/offer" || target.hasPrefix("/api/offer?") {
      let length = Int(headers["content-length"] ?? "0") ?? 0
      guard length > 0, length < 4_000_000 else {
        send(connection, status: 400, json: ["error": "bad body"], origin: origin)
        return
      }
      readBody(connection, remainder: remainder, length: length) { body in
        Task { @MainActor in
          await self.answerOffer(connection, body: body, origin: origin)
        }
      }
      return
    }

    send(connection, status: 404, json: ["error": "not found"], origin: origin)
  }

  private func answerOffer(_ connection: NWConnection, body: Data, origin: String?) async {
    guard let offer = try? JSONDecoder().decode(OfferRequest.self, from: body) else {
      send(connection, status: 400, json: ["error": "bad offer json"], origin: origin)
      return
    }
    let result = await onOffer?(offer) ?? .noStream
    switch result {
    case .answer(let sdp):
      send(connection, status: 200, json: ["sdp": sdp, "type": "answer"], origin: origin)
    case .noStream:
      send(connection, status: 404, json: ["error": "no such live stream"], origin: origin)
    case .failure(let message):
      send(connection, status: 500, json: ["error": message], origin: origin)
    }
  }

  private func queryParam(_ target: String, name: String) -> String? {
    guard let qi = target.firstIndex(of: "?") else { return nil }
    let query = target[target.index(after: qi)...]
    for pair in query.split(separator: "&") {
      let kv = pair.split(separator: "=", maxSplits: 1)
      if kv.count == 2, kv[0] == name { return String(kv[1]) }
    }
    return nil
  }

  // MARK: - Responses

  private func send<T: Encodable>(
    _ connection: NWConnection, status: Int, json: T?, origin: String?
  ) {
    var body = Data()
    if let json, let encoded = try? JSONEncoder().encode(json) {
      body = encoded
    }
    let reason: String
    switch status {
    case 200: reason = "OK"
    case 204: reason = "No Content"
    case 400: reason = "Bad Request"
    case 403: reason = "Forbidden"
    case 404: reason = "Not Found"
    default: reason = "Error"
    }
    var head = "HTTP/1.1 \(status) \(reason)\r\n"
    if let origin, allowedOrigins.contains(origin) {
      // Narrow echo, never "*": a blocked origin gets no read grant at all.
      head += "Access-Control-Allow-Origin: \(origin)\r\n"
      head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
      head += "Access-Control-Allow-Headers: Content-Type\r\n"
      head += "Vary: Origin\r\n"
    }
    if body.isEmpty {
      head += "Content-Length: 0\r\n"
    } else {
      head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n"
    }
    head += "Connection: close\r\n\r\n"
    var response = Data(head.utf8)
    response.append(body)
    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
  }
}
