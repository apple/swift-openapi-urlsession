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
import XCTest
import OpenAPIRuntime
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenAPIURLSession

class URLSessionTransportTests: XCTestCase {

    func testRequestConversion() throws {
        let request = OpenAPIRuntime.Request(
            path: "/hello/Maria",
            query: "greeting=Howdy",
            method: .post,
            headerFields: [
                .init(name: "X-Mumble", value: "mumble")
            ],
            body: Data("👋".utf8)
        )
        let urlRequest = try URLRequest(request, baseURL: URL(string: "http://example.com/api")!)
        XCTAssertEqual(urlRequest.url, URL(string: "http://example.com/api/hello/Maria?greeting=Howdy"))
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.allHTTPHeaderFields, ["X-Mumble": "mumble"])
        XCTAssertEqual(urlRequest.httpBody, Data("👋".utf8))
    }

    func testResponseConversion() throws {
        let urlResponse: URLResponse = HTTPURLResponse(
            url: URL(string: "http://example.com/api/hello/Maria?greeting=Howdy")!,
            statusCode: 201,
            httpVersion: "HTTP/1.1",
            headerFields: ["X-Mumble": "mumble"]
        )!
        let response = try OpenAPIRuntime.Response(from: urlResponse, body: Data("👋".utf8))
        XCTAssertEqual(response.statusCode, 201)
        XCTAssertEqual(response.headerFields, [.init(name: "X-Mumble", value: "mumble")])
        XCTAssertEqual(response.body, Data("👋".utf8))
    }

    func testSend() async throws {
        let endpointURL = URL(string: "http://example.com/api/hello/Maria?greeting=Howdy")!
        MockURLProtocol.mockHTTPResponses[endpointURL] = .success(
            (
                HTTPURLResponse(url: endpointURL, statusCode: 201, httpVersion: nil, headerFields: [:])!,
                body: Data("👋".utf8)
            )
        )
        let transport: ClientTransport = URLSessionTransport(
            configuration: .init(session: MockURLProtocol.mockURLSession)
        )
        let request = OpenAPIRuntime.Request(
            path: "/hello/Maria",
            query: "greeting=Howdy",
            method: .post,
            headerFields: [
                .init(name: "X-Mumble", value: "mumble")
            ]
        )
        let response = try await transport.send(
            request,
            baseURL: URL(string: "http://example.com/api")!,
            operationID: "postGreeting"
        )
        XCTAssertEqual(response.statusCode, 201)
        XCTAssertEqual(response.body, Data("👋".utf8))
    }
}

class MockURLProtocol: URLProtocol {
    static var mockHTTPResponses: [URL: Result<(response: HTTPURLResponse, body: Data?), Error>] = [:]

    static var recordedHTTPRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func stopLoading() {}

    override func startLoading() {
        Self.recordedHTTPRequests.append(self.request)
        guard let url = self.request.url else { return }
        guard let response = Self.mockHTTPResponses[url] else { return }
        switch response {
        case .success(let mockResponse):
            client?.urlProtocol(self, didReceive: mockResponse.response, cacheStoragePolicy: .notAllowed)
            if let data = mockResponse.body {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    static var mockURLSession: URLSession {
        let configuration: URLSessionConfiguration = .ephemeral
        configuration.protocolClasses = [Self.self]
        configuration.timeoutIntervalForRequest = 0.1
        configuration.timeoutIntervalForResource = 0.1
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }
}
