import Foundation
import CryptoKit

enum DownloadError: LocalizedError {
    case http(Int)
    case checksumMismatch

    var errorDescription: String? {
        switch self {
        case .http(401), .http(403): return "Download was refused. Check your access token."
        case .http(404): return "The release file was not found."
        case .http(let code): return "Download failed (HTTP \(code))."
        case .checksumMismatch: return "Downloaded file failed its SHA-256 check."
        }
    }
}

/// One-shot file download with progress reporting. Drops the Authorization
/// header when GitHub redirects an asset download to its storage host.
final class Downloader: NSObject, URLSessionDownloadDelegate {
    private let destination: URL
    private let expectedSize: Int64?
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var failure: Error?
    private var session: URLSession?

    private init(destination: URL, expectedSize: Int64?, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.expectedSize = expectedSize
        self.onProgress = onProgress
    }

    static func download(
        _ request: URLRequest,
        to destination: URL,
        expectedSize: Int64? = nil,
        sha256: String? = nil,
        onProgress: @escaping (Double) -> Void
    ) async throws -> URL {
        let downloader = Downloader(destination: destination, expectedSize: expectedSize, onProgress: onProgress)
        let url = try await downloader.run(request)
        if let sha256, !sha256.isEmpty {
            let digest = try await Task.detached(priority: .utility) { () -> String in
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }.value
            guard digest.caseInsensitiveCompare(sha256) == .orderedSame else {
                try? FileManager.default.removeItem(at: url)
                throw DownloadError.checksumMismatch
            }
        }
        return url
    }

    private func run(_ request: URLRequest) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let configuration = URLSessionConfiguration.default
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 60 * 30
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                session.downloadTask(with: request).resume()
            }
        } onCancel: { [weak self] in
            self?.session?.invalidateAndCancel()
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (expectedSize ?? 0)
        guard total > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            failure = DownloadError.http(http.statusCode)
            return
        }
        do {
            let fm = FileManager.default
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<URL, Error>
        if let error = error ?? failure {
            result = .failure(error)
        } else {
            result = .success(destination)
        }
        continuation?.resume(with: result)
        continuation = nil
        session.finishTasksAndInvalidate()
        self.session = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var redirected = request
        if request.url?.host != task.originalRequest?.url?.host {
            // Pre-signed storage URLs reject requests that also carry a bearer token.
            redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(redirected)
    }
}
