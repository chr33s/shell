import Foundation
import NIO
import XCTest
import Citadel

/// Drives the system `sftp-server` over plain pipes, which exercises
/// `SFTPClient.connect(rawChannel:)` and the setstat/lstat/symlink/readlink calls.
final class SFTPRawChannelTests: XCTestCase {
    private static let serverPath = "/usr/libexec/sftp-server"

    func testRawChannelFileManagement() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: Self.serverPath))

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let process = Process()
        let toServer = Pipe()
        let fromServer = Pipe()
        process.executableURL = URL(fileURLWithPath: Self.serverPath)
        process.standardInput = toServer
        process.standardOutput = fromServer
        try process.run()

        let channel = try await NIOPipeBootstrap(group: group)
            .takingOwnershipOfDescriptors(
                input: dup(fromServer.fileHandleForReading.fileDescriptor),
                output: dup(toServer.fileHandleForWriting.fileDescriptor)
            ).get()
        let sftp = try await SFTPClient.connect(rawChannel: channel)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("citadel-sftp-\(UUID().uuidString)").path
        try await sftp.createDirectory(atPath: root)

        let file = root + "/file.txt"
        try await sftp.withFile(filePath: file, flags: [.create, .write]) { handle in
            try await handle.write(ByteBuffer(string: "hello"))
        }

        var attributes = SFTPFileAttributes()
        attributes.permissions = 0o640
        try await sftp.setAttributes(at: file, attributes: attributes)
        let stat = try await sftp.getAttributes(at: file)
        XCTAssertEqual((stat.permissions ?? 0) & 0o777, 0o640)

        let link = root + "/link"
        try await sftp.createSymlink(linkPath: link, targetPath: file)
        let target = try await sftp.readLink(at: link)
        XCTAssertEqual(target, file)
        let linkStat = try await sftp.getLinkAttributes(at: link)
        XCTAssertEqual((linkStat.permissions ?? 0) & 0o170000, 0o120000)

        try await sftp.remove(at: link)
        try await sftp.remove(at: file)
        try await sftp.rmdir(at: root)
        try await sftp.close()
        process.terminate()
        try await group.shutdownGracefully()
    }
}
