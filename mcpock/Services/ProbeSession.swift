import Foundation

/// The URLSession every HTTP and SSE probe uses. A redirect is followed only
/// to the configured server's own scheme, host and port: the request carries
/// the config's headers (`X-Api-Key`, a helper's token), and Foundation drops
/// only `Authorization` on its own (review 2026-10-20, e13c). A redirect
/// elsewhere is not followed, and its 3xx answer is the result. Ephemeral, so
/// a server's cookies never outlive the app.
final class ProbeSession: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = URLSession(configuration: .ephemeral, delegate: ProbeSession(), delegateQueue: nil)

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url, let target = request.url,
              SSEProbe.isSameOrigin(target, as: original)
        else { return completionHandler(nil) }
        completionHandler(request)
    }
}
