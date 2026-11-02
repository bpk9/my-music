import Foundation
import CryptoKit
import Security
import UIKit
import ImageIO

struct Connection {
    let url: URL
    let token: String
    let pin: String
    static let current: Connection? = {
        guard let file = Bundle.main.url(forResource: "Connection", withExtension: "plist"),
              let data = try? Data(contentsOf: file),
              let p = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String:String],
              let raw = p["ServerURL"], let url = URL(string: raw), url.scheme == "https",
              let token = p["ServerToken"], token.count >= 32,
              let pin = p["CertificateSHA256"], pin.count == 64 else { return nil }
        return Connection(url: url, token: token, pin: pin)
    }()
    func credential(_ challenge: URLAuthenticationChallenge) -> URLCredential? {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == url.host,
              challenge.protectionSpace.port == (url.port ?? 443),
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let cert = chain.first else { return nil }
        let digest = SHA256.hash(data: SecCertificateCopyData(cert) as Data).map { String(format: "%02x", $0) }.joined()
        return digest == pin ? URLCredential(trust: trust) : nil
    }
}
class PinnedDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let credential = Connection.current?.credential(challenge) { completionHandler(.useCredential, credential) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
final class API: @unchecked Sendable {
    static let shared = API()
    let session: URLSession
    private let delegate = PinnedDelegate()
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }
    func request(_ path: String, method: String = "GET") throws -> URLRequest {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--test-offline") { throw URLError(.notConnectedToInternet) }
        #endif
        guard let c = Connection.current else { throw NSError(domain:"MyMusic",code:1,userInfo:[NSLocalizedDescriptionKey:"Connect your music server to this build first."]) }
        var request = URLRequest(url: c.url.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer " + c.token, forHTTPHeaderField: "Authorization")
        return request
    }
    func data(_ path: String, method: String = "GET") async throws -> Data {
        let (data, response) = try await session.data(for: request(path, method: method))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain:"MyMusic",code:2,userInfo:[NSLocalizedDescriptionKey:"Your library could not complete the request. Refresh and try again."])
        }
        return data
    }
}
@MainActor final class ArtworkStore {
    static let shared = ArtworkStore()
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    init() { cache.countLimit = 80; cache.totalCostLimit = 48 * 1024 * 1024 }
    func image(_ track: Track) async -> UIImage? {
        if let image = cache.object(forKey: track.albumID as NSString) { return image }
        if let task = inFlight[track.albumID] { return await task.value }
        let task = Task<UIImage?, Never> {
            let path = Disk.root.appendingPathComponent(track.id + ".art")
            let data: Data
            if let saved = try? Data(contentsOf: path) { data = saved }
            else {
                guard let fetched = try? await API.shared.data("v1/tracks/\(track.id)/art") else { return nil }
                data = fetched
                // Cache compressed art for offline use; never cache full decoded library artwork.
                try? data.write(to: path, options: .atomic)
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways:true, kCGImageSourceThumbnailMaxPixelSize:700, kCGImageSourceCreateThumbnailWithTransform:true] as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }
        inFlight[track.albumID] = task
        let result = await task.value
        inFlight[track.albumID] = nil
        if let result { cache.setObject(result, forKey: track.albumID as NSString, cost: Int(result.size.width * result.size.height * 4)) }
        return result
    }
}
