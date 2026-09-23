//===----------------------------------------------------------------------===//
//
// This source file is part of the SwiftNIO open source project
//
// Copyright (c) 2026 Apple Inc. and the SwiftNIO project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of SwiftNIO project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Crypto
import NIOCore
@testable import NIOSSH
import XCTest

final class KeyDerivationTests: XCTestCase {
    /// RFC 4253 §7.2 key expansion: K1 = HASH(K || H || X || sid), K2 = HASH(K || H || K1), K3 = HASH(K || H || K1 || K2).
    func testDerivedKeysExpandBeyondOneDigest() {
        var base = SHA256()
        base.update(data: [0x01, 0x02, 0x03, 0x04]) // stands in for K || H
        let sessionID = ByteBuffer(bytes: [0x09, 0x08, 0x07])

        var k1Hasher = base
        k1Hasher.update(data: [UInt8(ascii: "E")])
        k1Hasher.update(data: sessionID.readableBytesView)
        let k1 = Array(k1Hasher.finalize())

        var k2Hasher = base
        k2Hasher.update(data: k1)
        let k2 = Array(k2Hasher.finalize())

        var k3Hasher = base
        k3Hasher.update(data: k1 + k2)
        let k3 = Array(k3Hasher.finalize())

        XCTAssertEqual(expandDerivedKey(baseHasher: base, discriminatorByte: UInt8(ascii: "E"), sessionID: sessionID, size: 20), Array(k1.prefix(20)))
        XCTAssertEqual(expandDerivedKey(baseHasher: base, discriminatorByte: UInt8(ascii: "E"), sessionID: sessionID, size: 32), k1)
        XCTAssertEqual(expandDerivedKey(baseHasher: base, discriminatorByte: UInt8(ascii: "E"), sessionID: sessionID, size: 64), k1 + k2)
        XCTAssertEqual(expandDerivedKey(baseHasher: base, discriminatorByte: UInt8(ascii: "E"), sessionID: sessionID, size: 70), Array((k1 + k2 + k3).prefix(70)))
    }
}
