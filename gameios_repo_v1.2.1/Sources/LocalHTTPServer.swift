//
//  LocalHTTPServer.swift
//  极简 HTTP/1.1 静态文件服务器（只服务 App 包内的 web 目录）
//
//  为什么不用 file:// 或自定义 scheme：
//    1. file:// 下 XHR / fetch 被 CORS 拦死，Cocos 的资源加载全部走 XHR → 白屏
//    2. game:// 这类自定义 scheme 在 WKWebView 里对 wasm 流式编译、跨域头、range 都有坑
//    3. 本地回环 http 与线上网页版行为 100% 一致，最稳
//

import Foundation
import Network

final class LocalHTTPServer {

    static let shared = LocalHTTPServer()

    private let queue = DispatchQueue(label: "com.jinlin.game.http")
    private var listener: NWListener?
    private var webRoot: URL?

    private init() {}

    // MARK: - 启动

    func start(rootURL: URL, onReady: @escaping (UInt16) -> Void) {
        webRoot = rootURL
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.acceptLocalOnly = true

            let l = try NWListener(using: params, on: NWEndpoint.Port.any)
            l.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            l.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let port = l.port?.rawValue ?? 0
                    print("[http] listening on 127.0.0.1:\(port), root=\(rootURL.path)")
                    self?.listener = l
                    onReady(port)
                case .failed(let err):
                    print("[http] listener failed: \(err)")
                case .cancelled:
                    print("[http] listener cancelled")
                default:
                    break
                }
            }
            l.start(queue: queue)
            self.listener = l
        } catch {
            print("[http] cannot start listener: \(error)")
        }
    }

    // MARK: - 连接

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self = self else {
                conn.cancel()
                return
            }
            var buf = buffer
            if let c = chunk, !c.isEmpty { buf.append(c) }

            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headData = buf.subdata(in: 0..<range.upperBound)
                let head = String(data: headData, encoding: .utf8) ?? ""
                self.respond(conn, head: head)
                return
            }
            if isComplete || error != nil || buf.count > 256 * 1024 {
                conn.cancel()
                return
            }
            self.read(conn, buffer: buf)
        }
    }

    // MARK: - 请求解析

    private func respond(_ conn: NWConnection, head: String) {
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else {
            reply(conn, status: 400, reason: "Bad Request", mime: "text/plain", body: Data("bad request".utf8))
            return
        }
        let parts = first.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            reply(conn, status: 400, reason: "Bad Request", mime: "text/plain", body: Data("bad request".utf8))
            return
        }
        let method = String(parts[0]).uppercased()
        var target = String(parts[1])
        if let cut = target.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            target = String(target[target.startIndex..<cut])
        }
        let path = target.removingPercentEncoding ?? target

        var rangeHeader: String?
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("range:") {
                rangeHeader = String(line.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces)
            }
        }

        guard let root = webRoot else {
            reply(conn, status: 503, reason: "Service Unavailable", mime: "text/plain", body: Data("no root".utf8))
            return
        }

        var rel = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if rel.isEmpty { rel = "wz.html" }
        if rel.contains("..") {
            print("[http] 403 \(method) /\(rel)")
            reply(conn, status: 403, reason: "Forbidden", mime: "text/plain", body: Data("forbidden".utf8))
            return
        }

        if let fileURL = resolve(root: root, rel: rel) {
            serve(conn, method: method, fileURL: fileURL, range: rangeHeader)
        } else {
            print("[http] 404 \(method) /\(rel)")
            reply(conn, status: 404, reason: "Not Found", mime: "text/plain", body: Data("404 not found".utf8))
        }
    }

    private func resolve(root: URL, rel: String) -> URL? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let direct = root.appendingPathComponent(rel)
        if fm.fileExists(atPath: direct.path, isDirectory: &isDir) {
            if isDir.boolValue {
                let index = direct.appendingPathComponent("index.html")
                if fm.fileExists(atPath: index.path) { return index }
                return nil
            }
            return direct
        }
        // 无扩展名的路径兜底成目录
        if !rel.contains(".") {
            let index = direct.appendingPathComponent("index.html")
            if fm.fileExists(atPath: index.path) { return index }
        }
        return nil
    }

    // MARK: - 响应

    private func serve(_ conn: NWConnection, method: String, fileURL: URL, range: String?) {
        let mime = LocalHTTPServer.mimeType(for: fileURL.pathExtension)
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        } catch {
            print("[http] 500 read \(fileURL.lastPathComponent): \(error)")
            reply(conn, status: 500, reason: "Internal Server Error", mime: "text/plain", body: Data("read error".utf8))
            return
        }

        let total = data.count
        let name = fileURL.path

        if method == "HEAD" {
            print("[http] 200 HEAD \(name)")
            reply(conn, status: 200, reason: "OK", mime: mime, body: Data(),
                  lengthOverride: total, sendBody: false)
            return
        }

        var start = 0
        var end = total - 1
        var status = 200
        var reason = "OK"
        var extra: [String: String] = [:]

        if let r = range, r.lowercased().hasPrefix("bytes=") {
            let spec = r.dropFirst("bytes=".count).split(separator: ",").first.map(String.init) ?? ""
            let comps = spec.split(separator: "-", omittingEmptySubsequences: false)
            if comps.count == 2 {
                let s = String(comps[0]).trimmingCharacters(in: .whitespaces)
                let e = String(comps[1]).trimmingCharacters(in: .whitespaces)
                if !s.isEmpty, let sv = Int(s) { start = max(0, sv) }
                if !e.isEmpty, let ev = Int(e) { end = min(total - 1, ev) }
                if total > 0 && start <= end {
                    status = 206
                    reason = "Partial Content"
                    extra["Content-Range"] = "bytes \(start)-\(end)/\(total)"
                } else {
                    start = 0
                    end = total - 1
                }
            }
        }

        let body = (status == 206) ? data.subdata(in: start..<(end + 1)) : data
        print("[http] \(status) \(method) \(name) \(body.count)B")
        reply(conn, status: status, reason: reason, mime: mime, body: body, extra: extra)
    }

    private func reply(_ conn: NWConnection,
                       status: Int,
                       reason: String,
                       mime: String,
                       body: Data,
                       extra: [String: String] = [:],
                       lengthOverride: Int? = nil,
                       sendBody: Bool = true) {
        let length = lengthOverride ?? body.count
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: \(mime)\r\n"
        head += "Content-Length: \(length)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        // 资源全在本地，禁掉缓存可以保证改完资源立刻生效，也不会把沙盒撑爆
        head += "Cache-Control: no-cache\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n"
        for (k, v) in extra { head += "\(k): \(v)\r\n" }
        head += "\r\n"

        var out = Data(head.utf8)
        if sendBody { out.append(body) }

        if out.count <= 256 * 1024 {
            conn.send(content: out, contentContext: .defaultMessage, isComplete: true,
                      completion: .contentProcessed { _ in conn.cancel() })
            return
        }

        // 大文件分块发送，避免一次性塞 10MB 导致内存飙升
        var offset = 0
        let chunkSize = 256 * 1024
        func sendChunk() {
            let end = min(offset + chunkSize, out.count)
            let chunk = out.subdata(in: offset..<end)
            let isLast = end >= out.count
            conn.send(content: chunk, contentContext: .defaultMessage, isComplete: isLast,
                      completion: .contentProcessed { err in
                if err != nil || isLast {
                    conn.cancel()
                    return
                }
                offset = end
                sendChunk()
            })
        }
        sendChunk()
    }

    // MARK: - MIME

    static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "json", "plist": return "application/json; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "wasm": return "application/wasm"
        case "txt", "xml", "atlas": return "text/plain; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "bmp": return "image/bmp"
        case "mp3": return "audio/mpeg"
        case "ogg", "oga": return "audio/ogg"
        case "wav": return "audio/wav"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "mp4", "m4v": return "video/mp4"
        case "webm": return "video/webm"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "fnt": return "text/plain; charset=utf-8"
        case "skel", "bin", "dat", "cconb": return "application/octet-stream"
        default: return "application/octet-stream"
        }
    }
}
