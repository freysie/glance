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
      send(connection, status: 400, json: ["error": "bad request"])
      return
    }
    let lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.first?.components(separatedBy: " ") ?? []
    guard requestLine.count >= 2 else {
      send(connection, status: 400, json: ["error": "bad request"])
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

    if method == "OPTIONS" {
      send(connection, status: 204, json: Optional<[String: String]>.none)
      return
    }

    if method == "GET", target == "/api/ping" || target.hasPrefix("/api/ping?") {
      send(connection, status: 200, json: ["ok": "true"])
      return
    }

    if method == "GET", target.hasPrefix("/api/status") {
      let id = queryParam(target, name: "stream") ?? ""
      let snapshot = statusProvider?(id) ?? StatusSnapshot(live: false, viewers: 0)
      send(connection, status: 200, json: snapshot)
      return
    }

    if method == "POST", target == "/api/offer" || target.hasPrefix("/api/offer?") {
      let length = Int(headers["content-length"] ?? "0") ?? 0
      guard length > 0, length < 4_000_000 else {
        send(connection, status: 400, json: ["error": "bad body"])
        return
      }
      readBody(connection, remainder: remainder, length: length) { body in
        Task { @MainActor in
          await self.answerOffer(connection, body: body)
        }
      }
      return
    }

    send(connection, status: 404, json: ["error": "not found"])
  }

  private func answerOffer(_ connection: NWConnection, body: Data) async {
    guard let offer = try? JSONDecoder().decode(OfferRequest.self, from: body) else {
      send(connection, status: 400, json: ["error": "bad offer json"])
      return
    }
    let result = await onOffer?(offer) ?? .noStream
    switch result {
    case .answer(let sdp):
      send(connection, status: 200, json: ["sdp": sdp, "type": "answer"])
    case .noStream:
      send(connection, status: 404, json: ["error": "no such live stream"])
    case .failure(let message):
      send(connection, status: 500, json: ["error": message])
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

  private func send<T: Encodable>(_ connection: NWConnection, status: Int, json: T?) {
    var body = Data()
    if let json, let encoded = try? JSONEncoder().encode(json) {
      body = encoded
    }
    let reason: String
    switch status {
    case 200: reason = "OK"
    case 204: reason = "No Content"
    case 400: reason = "Bad Request"
    case 404: reason = "Not Found"
    default: reason = "Error"
    }
    var head =
      "HTTP/1.1 \(status) \(reason)\r\n" + "Access-Control-Allow-Origin: *\r\n"
      + "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
      + "Access-Control-Allow-Headers: Content-Type\r\n"
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
