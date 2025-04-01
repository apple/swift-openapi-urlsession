//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftOpenAPIGenerator open source project
//
// Copyright (c) 2023 Apple Inc. and the SwiftOpenAPIGenerator project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftOpenAPIGenerator project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//
import OpenAPIRuntime
import HTTPTypes
#if canImport(Darwin)
import Foundation
#else
@preconcurrency import struct Foundation.URL
import struct Foundation.URLComponents
import struct Foundation.Data
import protocol Foundation.LocalizedError
import class Foundation.FileHandle
#if canImport(FoundationNetworking)
@preconcurrency import struct FoundationNetworking.URLRequest
import class FoundationNetworking.URLSession
import class FoundationNetworking.URLSessionTask
import class FoundationNetworking.URLResponse
import class FoundationNetworking.HTTPURLResponse
#endif
#endif

/// A client transport that performs HTTP operations using the URLSession type
/// provided by the Foundation framework.
///
/// ### Use the URLSession transport
///
/// Instantiate the transport:
///
///     let transport = URLSessionTransport()
///
/// Instantiate the `Client` type generated by the Swift OpenAPI Generator for
/// your provided OpenAPI document. For example:
///
///     let client = Client(
///         serverURL: URL(string: "https://example.com")!,
///         transport: transport
///     )
///
/// Use the client to make HTTP calls defined in your OpenAPI document. For
/// example, if the OpenAPI document contains an HTTP operation with
/// the identifier `checkHealth`, call it from Swift with:
///
///     let response = try await client.checkHealth()
///
/// ### Provide a custom URLSession
///
/// The ``URLSessionTransport/Configuration-swift.struct`` type allows you to
/// provide a custom URLSession and tweak behaviors such as the default
/// timeouts, authentication challenges, and more.
public struct URLSessionTransport: ClientTransport {

    /// A set of configuration values for the URLSession transport.
    public struct Configuration: Sendable {

        /// The URLSession used for performing HTTP operations.
        public var session: URLSession

        /// Creates a new configuration with the provided session.
        /// - Parameters:
        ///   - session: The URLSession used for performing HTTP operations.
        ///   - httpBodyProcessingMode: The mode used to process HTTP request and response bodies.
        public init(session: URLSession = .shared, httpBodyProcessingMode: HTTPBodyProcessingMode = .platformDefault) {
            let implementation = httpBodyProcessingMode.implementation
            self.init(session: session, implementation: implementation)
        }
        /// Creates a new configuration with the provided session.
        /// - Parameter session: The URLSession used for performing HTTP operations.
        public init(session: URLSession) { self.init(session: session, implementation: .platformDefault) }
        /// Specifies the mode in which HTTP request and response bodies are processed.
        public struct HTTPBodyProcessingMode: Sendable {
            /// Exposing the internal implementation directly.
            fileprivate let implementation: Configuration.Implementation

            private init(_ implementation: Configuration.Implementation) { self.implementation = implementation }

            /// Use this mode to force URLSessionTransport to transfer data in a buffered mode, even if
            /// streaming would be available on the platform.
            public static let buffered = HTTPBodyProcessingMode(.buffering)
            /// Data is transfered via streaming if available on the platform, else it falls back to buffering.
            public static let platformDefault = HTTPBodyProcessingMode(.platformDefault)
        }

        enum Implementation {
            case buffering
            case streaming(requestBodyStreamBufferSize: Int, responseBodyStreamWatermarks: (low: Int, high: Int))
        }

        var implementation: Implementation
        init(session: URLSession = .shared, implementation: Implementation = .platformDefault) {
            self.session = session
            if case .streaming = implementation {
                precondition(Implementation.platformSupportsStreaming, "Streaming not supported on platform")
            }
            self.implementation = implementation
        }

    }

    /// A set of configuration values used by the transport.
    public var configuration: Configuration

    /// Creates a new URLSession-based transport.
    /// - Parameter configuration: A set of configuration values used by the transport.
    public init(configuration: Configuration = .init(httpBodyProcessingMode: .platformDefault)) {
        self.configuration = configuration
    }

    /// Sends the underlying HTTP request and returns the received HTTP response.
    /// - Parameters:
    ///   - request: An HTTP request.
    ///   - requestBody: An HTTP request body.
    ///   - baseURL: A server base URL.
    ///   - operationID: The identifier of the OpenAPI operation.
    /// - Returns: An HTTP response and its body.
    /// - Throws: If there was an error performing the HTTP request.
    public func send(_ request: HTTPRequest, body requestBody: HTTPBody?, baseURL: URL, operationID: String)
        async throws -> (HTTPResponse, HTTPBody?)
    {
        switch configuration.implementation {
        case .streaming(let requestBodyStreamBufferSize, let responseBodyStreamWatermarks):
            #if canImport(Darwin)
            guard #available(macOS 12, iOS 15, tvOS 15, watchOS 8, *) else {
                throw URLSessionTransportError.streamingNotSupported
            }
            return try await configuration.session.bidirectionalStreamingRequest(
                for: request,
                baseURL: baseURL,
                requestBody: requestBody,
                requestStreamBufferSize: requestBodyStreamBufferSize,
                responseStreamWatermarks: responseBodyStreamWatermarks
            )
            #else
            throw URLSessionTransportError.streamingNotSupported
            #endif
        case .buffering:
            return try await configuration.session.bufferedRequest(
                for: request,
                baseURL: baseURL,
                requestBody: requestBody
            )
        }
    }
}

extension HTTPBody.Length {
    init(from urlResponse: URLResponse) {
        if urlResponse.expectedContentLength == -1 {
            self = .unknown
        } else {
            self = .known(urlResponse.expectedContentLength)
        }
    }
}

/// Specialized error thrown by the transport.
internal enum URLSessionTransportError: Error {

    /// Invalid URL composed from base URL and received request.
    case invalidRequestURL(path: String, method: HTTPRequest.Method, baseURL: URL)

    /// Returned `URLResponse` could not be converted to `HTTPURLResponse`.
    case notHTTPResponse(URLResponse)

    /// Returned `HTTPURLResponse` has an invalid status code
    case invalidResponseStatusCode(HTTPURLResponse)

    /// Returned `URLResponse` was nil
    case noResponse(url: URL?)

    /// Platform does not support streaming.
    case streamingNotSupported
}

extension HTTPResponse {
    init(_ urlResponse: URLResponse) throws {
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw URLSessionTransportError.notHTTPResponse(urlResponse)
        }
        guard (0...999).contains(httpResponse.statusCode) else {
            throw URLSessionTransportError.invalidResponseStatusCode(httpResponse)
        }
        self.init(status: .init(code: httpResponse.statusCode))
        if let fields = httpResponse.allHeaderFields as? [String: String] {
            self.headerFields.reserveCapacity(fields.count)
            for (name, value) in fields {
                if let name = HTTPField.Name(name) {
                    self.headerFields.append(HTTPField(name: name, isoLatin1Value: value))
                }
            }
        }
    }
}

extension URLRequest {
    init(_ request: HTTPRequest, baseURL: URL) throws {
        guard var baseUrlComponents = URLComponents(string: baseURL.absoluteString),
            let requestUrlComponents = URLComponents(string: request.path ?? "")
        else {
            throw URLSessionTransportError.invalidRequestURL(
                path: request.path ?? "<nil>",
                method: request.method,
                baseURL: baseURL
            )
        }

        let path = requestUrlComponents.percentEncodedPath
        baseUrlComponents.percentEncodedPath += path
        baseUrlComponents.percentEncodedQuery = requestUrlComponents.percentEncodedQuery
        guard let url = baseUrlComponents.url else {
            throw URLSessionTransportError.invalidRequestURL(path: path, method: request.method, baseURL: baseURL)
        }
        self.init(url: url)
        self.httpMethod = request.method.rawValue
        var combinedFields = [HTTPField.Name: String](minimumCapacity: request.headerFields.count)
        for field in request.headerFields {
            if let existingValue = combinedFields[field.name] {
                let separator = field.name == .cookie ? "; " : ", "
                combinedFields[field.name] = "\(existingValue)\(separator)\(field.isoLatin1Value)"
            } else {
                combinedFields[field.name] = field.isoLatin1Value
            }
        }
        var headerFields = [String: String](minimumCapacity: combinedFields.count)
        for (name, value) in combinedFields { headerFields[name.rawName] = value }
        self.allHTTPHeaderFields = headerFields
    }
}

extension String { fileprivate var isASCII: Bool { self.utf8.allSatisfy { $0 & 0x80 == 0 } } }

extension HTTPField {
    fileprivate init(name: Name, isoLatin1Value: String) {
        if isoLatin1Value.isASCII {
            self.init(name: name, value: isoLatin1Value)
        } else {
            self = withUnsafeTemporaryAllocation(of: UInt8.self, capacity: isoLatin1Value.unicodeScalars.count) {
                buffer in
                for (index, scalar) in isoLatin1Value.unicodeScalars.enumerated() {
                    if scalar.value > UInt8.max {
                        buffer[index] = 0x20
                    } else {
                        buffer[index] = UInt8(truncatingIfNeeded: scalar.value)
                    }
                }
                return HTTPField(name: name, value: buffer)
            }
        }
    }

    fileprivate var isoLatin1Value: String {
        if self.value.isASCII { return self.value }
        return self.withUnsafeBytesOfValue { buffer in
            let scalars = buffer.lazy.map { UnicodeScalar(UInt32($0))! }
            var string = ""
            string.unicodeScalars.append(contentsOf: scalars)
            return string
        }
    }
}

extension URLSessionTransportError: LocalizedError {
    /// A localized message describing what error occurred.
    var errorDescription: String? { description }
}

extension URLSessionTransportError: CustomStringConvertible {
    /// A textual representation of this instance.
    var description: String {
        switch self {
        case let .invalidRequestURL(path: path, method: method, baseURL: baseURL):
            return
                "Invalid request URL from request path: \(path), method: \(method), relative to base URL: \(baseURL.absoluteString)"
        case .notHTTPResponse(let response):
            return "Received a non-HTTP response, of type: \(String(describing: type(of: response)))"
        case .invalidResponseStatusCode(let response):
            return "Received an HTTP response with invalid status code: \(response.statusCode))"
        case .noResponse(let url): return "Received a nil response for \(url?.absoluteString ?? "<nil URL>")"
        case .streamingNotSupported: return "Streaming is not supported on this platform"
        }
    }
}

private let _debugLoggingEnabled = LockStorage.create(value: false)
var debugLoggingEnabled: Bool {
    get { _debugLoggingEnabled.withLockedValue { $0 } }
    set { _debugLoggingEnabled.withLockedValue { $0 = newValue } }
}
private let _standardErrorLock = LockStorage.create(value: FileHandle.standardError)
func debug(_ message: @autoclosure () -> String, function: String = #function, file: String = #file, line: UInt = #line)
{
    assert(
        {
            if debugLoggingEnabled {
                _standardErrorLock.withLockedValue {
                    let logLine = "[\(function) \(file.split(separator: "/").last!):\(line)] \(message())\n"
                    $0.write(Data((logLine).utf8))
                }
            }
            return true
        }()
    )
}

extension URLSession {
    func bufferedRequest(for request: HTTPRequest, baseURL: URL, requestBody: HTTPBody?) async throws -> (
        HTTPResponse, HTTPBody?
    ) {
        try Task.checkCancellation()
        var urlRequest = try URLRequest(request, baseURL: baseURL)
        if let requestBody { urlRequest.httpBody = try await Data(collecting: requestBody, upTo: .max) }
        try Task.checkCancellation()

        /// Use `dataTask(with:completionHandler:)` here because `data(for:[delegate:]) async` is only available on
        /// Darwin platforms newer than our minimum deployment target, and not at all on Linux.
        let taskBox: LockedValueBox<URLSessionTask?> = .init(nil)
        return try await withTaskCancellationHandler {
            let (response, maybeResponseBodyData): (URLResponse, Data?) = try await withCheckedThrowingContinuation {
                continuation in
                let task = self.dataTask(with: urlRequest) { [urlRequest] data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    guard let response else {
                        continuation.resume(throwing: URLSessionTransportError.noResponse(url: urlRequest.url))
                        return
                    }
                    continuation.resume(with: .success((response, data)))
                }
                // Swift concurrency task cancelled here.
                taskBox.withLockedValue { boxedTask in
                    guard task.state == .suspended else {
                        debug("URLSession task cannot be resumed, probably because it was cancelled by onCancel.")
                        return
                    }
                    task.resume()
                    boxedTask = task
                }
            }

            let maybeResponseBody = maybeResponseBodyData.map { data in
                HTTPBody(data, length: HTTPBody.Length(from: response), iterationBehavior: .multiple)
            }
            return (try HTTPResponse(response), maybeResponseBody)
        } onCancel: {
            taskBox.withLockedValue { boxedTask in
                debug("Concurrency task cancelled, cancelling URLSession task.")
                boxedTask?.cancel()
                boxedTask = nil
            }
        }
    }
}

extension URLSessionTransport.Configuration.Implementation {
    static var platformSupportsStreaming: Bool {
        #if canImport(Darwin)
        guard #available(macOS 12, iOS 15, tvOS 15, watchOS 8, *) else { return false }
        _ = URLSession.bidirectionalStreamingRequest
        return true
        #else
        return false
        #endif
    }

    static var platformDefault: Self {
        guard platformSupportsStreaming else { return .buffering }
        return .streaming(
            requestBodyStreamBufferSize: 16 * 1024,
            responseBodyStreamWatermarks: (low: 16 * 1024, high: 32 * 1024)
        )
    }
}
