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
@preconcurrency import struct Foundation.URLComponents
@preconcurrency import struct Foundation.Data
@preconcurrency import protocol Foundation.LocalizedError
#endif
#if canImport(FoundationNetworking)
@preconcurrency import struct FoundationNetworking.URLRequest
@preconcurrency import class FoundationNetworking.URLSession
@preconcurrency import class FoundationNetworking.URLResponse
@preconcurrency import class FoundationNetworking.HTTPURLResponse
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
/// Create the base URL of the server to call using your client. If the server
/// URL was defined in the OpenAPI document, you find a generated method for it
/// on the `Servers` type, for example:
///
///     let serverURL = try Servers.server1()
///
/// Instantiate the `Client` type generated by the Swift OpenAPI Generator for
/// your provided OpenAPI document. For example:
///
///     let client = Client(
///         serverURL: serverURL,
///         transport: transport
///     )
///
/// Use the client to make HTTP calls defined in your OpenAPI document. For
/// example, if the OpenAPI document contains an HTTP operation with
/// the identifier `checkHealth`, call it from Swift with:
///
///     let response = try await client.checkHealth(.init())
///     // ...
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
        ///     - session: The URLSession used for performing HTTP operations.
        ///     If none is provided, the system uses the shared URLSession.
        public init(session: URLSession = .shared) {
            self.session = session
        }
    }

    /// A set of configuration values used by the transport.
    public var configuration: Configuration

    /// Creates a new URLSession-based transport.
    /// - Parameters:
    ///   - configuration: A set of configuration values used by the transport.
    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public func send(
        _ request: HTTPRequest,
        body: HTTPBody?,
        baseURL: URL,
        operationID: String
    ) async throws -> (HTTPResponse, HTTPBody) {
        // TODO: Investigate how to get bidirectional streaming working.
        let urlRequest = try await URLRequest(request, body: body, baseURL: baseURL)
        let (responseBody, urlResponse) = try await invokeSession(urlRequest)
        return try HTTPResponse.response(from: urlResponse, body: responseBody)
    }

    private func invokeSession(_ urlRequest: URLRequest) async throws -> (Data, URLResponse) {
        // Using `dataTask(with:completionHandler:)` instead of the async method `data(for:)` of URLSession because the latter is not available on linux platforms
        return try await withCheckedThrowingContinuation { continuation in
            configuration.session
                .dataTask(with: urlRequest) { data, response, error in
                    if let error {
                        continuation.resume(with: .failure(error))
                        return
                    }

                    guard let response else {
                        continuation.resume(
                            with: .failure(URLSessionTransportError.noResponse(url: urlRequest.url))
                        )
                        return
                    }

                    continuation.resume(
                        with: .success((data ?? Data(), response))
                    )
                }
                .resume()
        }
    }
}

/// Specialized error thrown by the transport.
internal enum URLSessionTransportError: Error {

    /// Invalid URL composed from base URL and received request.
    case invalidRequestURL(path: String, method: HTTPRequest.Method, baseURL: URL)

    /// Returned `URLResponse` could not be converted to `HTTPURLResponse`.
    case notHTTPResponse(URLResponse)

    /// Returned `URLResponse` was nil
    case noResponse(url: URL?)
}

extension HTTPResponse {
    static func response(
        from urlResponse: URLResponse,
        body: Data
    ) throws -> (HTTPResponse, HTTPBody) {
        guard let httpResponse = urlResponse as? HTTPURLResponse else {
            throw URLSessionTransportError.notHTTPResponse(urlResponse)
        }
        var headerFields = HTTPFields()
        for (headerName, headerValue) in httpResponse.allHeaderFields {
            guard
                let rawName = headerName as? String,
                let name = HTTPField.Name(rawName),
                let value = headerValue as? String
            else {
                continue
            }
            headerFields[name] = value
        }
        return (
            HTTPResponse(
                status: .init(code: httpResponse.statusCode),
                headerFields: headerFields
            ),
            .init(data: body)
        )
    }
}

extension URLRequest {
    init(_ request: HTTPRequest, body: HTTPBody?, baseURL: URL) async throws {
        guard var baseUrlComponents = URLComponents(string: baseURL.absoluteString) else {
            throw URLSessionTransportError.invalidRequestURL(
                path: request.path ?? "<nil>",
                method: request.method,
                baseURL: baseURL
            )
        }

        let path = String(request.soar_pathOnly)
        baseUrlComponents.percentEncodedPath += path
        baseUrlComponents.percentEncodedQuery = request.soar_query.map(String.init)
        guard let url = baseUrlComponents.url else {
            throw URLSessionTransportError.invalidRequestURL(
                path: path,
                method: request.method,
                baseURL: baseURL
            )
        }
        self.init(url: url)
        self.httpMethod = request.method.rawValue
        for header in request.headerFields {
            self.addValue(header.value, forHTTPHeaderField: header.name.canonicalName)
        }
        if let body {
            // TODO: Avoid buffering, stream intead.
            self.httpBody = try await Data(collecting: body, upTo: .max)
        }
    }
}

extension URLSessionTransportError: LocalizedError {
    public var errorDescription: String? { description }
}

extension URLSessionTransportError: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .invalidRequestURL(path: path, method: method, baseURL: baseURL):
            return
                "Invalid request URL from request path: \(path), method: \(method), relative to base URL: \(baseURL.absoluteString)"
        case .notHTTPResponse(let response):
            return "Received a non-HTTP response, of type: \(String(describing: type(of: response)))"
        case .noResponse(let url):
            return "Received a nil response for \(url?.absoluteString ?? "<nil URL>")"
        }
    }
}
