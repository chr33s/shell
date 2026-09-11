# Integrating ios_system Frameworks into Your Swift Application

This guide explains how to integrate the ios_system frameworks (built with visionOS support) into your iOS, iPadOS, macOS (Catalyst), or visionOS application.

## Overview

The ios_system frameworks provide Unix-like command execution capabilities for iOS/iPadOS/visionOS applications. After building, you'll have XCFrameworks that support:

- **iOS** (iPhone & iPad devices)
- **iOS Simulator** (iPhone & iPad simulators on Apple Silicon & Intel Macs)
- **Mac Catalyst** (macOS apps)
- **visionOS** (Apple Vision Pro device)
- **visionOS Simulator** (Apple Vision Pro simulator)

## Building the Frameworks

Build all frameworks with visionOS support:

```bash
swift run --package-path xcfs build
```

Or build specific frameworks:

```bash
swift run --package-path xcfs build ios_system,files,shell
```

The built XCFrameworks will be located in `.build/<framework_name>/<framework_name>.xcframework/`

## Integration Methods

### Method 1: Manual XCFramework Integration (Recommended for Local Development)

#### Step 1: Locate Built Frameworks

After building, frameworks are in:
```
.build/
├── ios_system/ios_system.xcframework/
├── files/files.xcframework/
├── shell/shell.xcframework/
├── text/text.xcframework/
├── tar/tar.xcframework/
├── awk/awk.xcframework/
├── curl_ios/curl_ios.xcframework/
├── ssh_cmd/ssh_cmd.xcframework/
└── ... (other frameworks)
```

#### Step 2: Add to Your Xcode Project

1. Open your Xcode project
2. Select your project in the Project Navigator
3. Select your app target
4. Go to **General** tab → **Frameworks, Libraries, and Embedded Content**
5. Click **+** button
6. Click **Add Other...** → **Add Files...**
7. Navigate to `.build/<framework_name>/` and select the `.xcframework` bundle
8. Set **Embed** to "Embed & Sign" (for app targets) or "Do Not Embed" (for framework targets)
9. Repeat for each framework you need

**Core Framework Dependency:**
- Always include `ios_system.framework` as it's required by all other frameworks
- Other frameworks are optional and can be added as needed

#### Step 3: Add Required Resources

The command dictionaries must be included in your app bundle:

1. In Xcode, select your target
2. Go to **Build Phases** → **Copy Bundle Resources**
3. Click **+** and add these files from the ios_system repository:
   - `Resources/commandDictionary.plist`
   - `Resources/extraCommandsDictionary.plist`

### Method 2: Swift Package Manager (For Published Releases)

If the frameworks are published as a Swift Package with binary targets:

#### Add Package Dependency

In your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/holzschu/ios_system", from: "3.0.0")
]
```

In your target dependencies:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "ios_system", package: "ios_system"),
        .product(name: "files", package: "ios_system"),
        .product(name: "shell", package: "ios_system"),
        // Add other frameworks as needed
    ]
)
```

#### Or via Xcode

1. **File** → **Add Package Dependencies...**
2. Enter repository URL: `https://github.com/holzschu/ios_system`
3. Select version/branch
4. Choose which framework products to add to your target

## Usage in Your Application

### Swift

```swift
import ios_system

class CommandRunner {
    func setup() {
        // Initialize environment (call once at app launch)
        initializeEnvironment()

        // Optional: Set custom I/O streams
        ios_setStreams(stdin, stdout, stderr)
    }

    func executeCommand(_ command: String) -> Int32 {
        // Execute a command
        let result = ios_system(command)
        return result
    }

    func checkCommandExists(_ command: String) -> Bool {
        // Check if a command is available
        return ios_executable(command) != nil
    }
}

// Example usage
let runner = CommandRunner()
runner.setup()

// Execute commands
runner.executeCommand("ls -la")
runner.executeCommand("grep pattern file.txt")
runner.executeCommand("tar -xzf archive.tar.gz")
```

### Objective-C

```objc
#import <ios_system/ios_system.h>

@interface CommandRunner : NSObject
@end

@implementation CommandRunner

- (void)setup {
    // Initialize environment (call once at app launch)
    initializeEnvironment();

    // Optional: Set custom I/O streams
    ios_setStreams(stdin, stdout, stderr);
}

- (int)executeCommand:(NSString *)command {
    // Execute a command
    int result = ios_system([command UTF8String]);
    return result;
}

- (BOOL)checkCommandExists:(NSString *)command {
    // Check if a command is available
    return ios_executable([command UTF8String]) != NULL;
}

@end

// Example usage
CommandRunner *runner = [[CommandRunner alloc] init];
[runner setup];

// Execute commands
[runner executeCommand:@"ls -la"];
[runner executeCommand:@"grep pattern file.txt"];
```

### Capturing Command Output

```swift
import Foundation
import ios_system

func executeAndCapture(_ command: String) -> String {
    // Create pipes for stdout
    let outputPipe = Pipe()
    let originalStdout = stdout

    // Redirect stdout to pipe
    ios_setStreams(stdin, fdopen(outputPipe.fileHandleForWriting.fileDescriptor, "w"), stderr)

    // Execute command
    ios_system(command)

    // Restore original stdout
    ios_setStreams(stdin, originalStdout, stderr)

    // Read captured output
    let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: outputData, encoding: .utf8) ?? ""
}

// Usage
let files = executeAndCapture("ls -1")
print("Files:\n\(files)")
```

## Platform-Specific Considerations

### iOS / iPadOS

- **File System Access:** Limited to app sandbox (~/Documents/, ~/Library/, ~/tmp/)
- **Permissions:** No special entitlements required
- **Environment:** Set HOME to writable directory:
  ```swift
  setenv("HOME", NSHomeDirectory(), 1)
  ```

### visionOS

- **Window Management:** The `open` command has limited functionality on visionOS
  - `openURL` API is not available on visionOS
  - File opening through UIActivityViewController may have different behavior
- **Spatial Computing:** Commands execute normally but UI-based operations may need adaptation
- **Environment:** Same sandbox restrictions as iOS

### Mac Catalyst

- **File Access:** Broader file system access compared to iOS (with proper entitlements)
- **Entitlements:** May need file access entitlements for certain directories
- **Environment:** More Unix-like environment, closer to macOS behavior

## Framework Dependencies

Different frameworks depend on `ios_system.framework`:

| Framework | Purpose | Dependencies |
|-----------|---------|--------------|
| **ios_system** | Core framework | None (always required) |
| **files** | File operations (cp, mv, rm, ls, etc.) | ios_system |
| **shell** | Shell utilities (echo, env, etc.) | ios_system |
| **text** | Text processing (cat, grep, sed, etc.) | ios_system |
| **tar** | Archive operations | ios_system |
| **awk** | AWK text processing | ios_system |
| **curl_ios** | Network operations (curl, scp, sftp) | ios_system, openssl, libssh2 |
| **ssh_cmd** | SSH client | ios_system, openssl, libssh2 |

**External Binary Dependencies:**
- `curl_ios` and `ssh_cmd` require `openssl` and `libssh2` XCFrameworks
- These are downloaded automatically when using Swift Package Manager
- For manual integration, obtain them from:
  - openssl: https://github.com/holzschu/openssl-apple
  - libssh2: https://github.com/holzschu/libssh2-apple

## Advanced Configuration

### Custom Command Registration

Add your own commands at runtime:

```swift
// Define your command function
func myCommand(argc: Int32, argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?) -> Int32 {
    print("My custom command executed!")
    return 0
}

// Register it
replaceCommand("mycommand", myCommand, false)

// Now you can execute it
ios_system("mycommand")
```

### Restricted Filesystem Access

Create a sandbox within the sandbox:

```swift
// Restrict all file operations to a specific directory
ios_setMiniRoot(NSHomeDirectory() + "/Documents/sandbox")

// Now all file commands operate within this restricted area
```

### Custom Command Dictionary

Load additional commands from a custom plist:

```swift
if let customCommandsPath = Bundle.main.path(forResource: "myCommands", ofType: "plist") {
    addCommandList(customCommandsPath)
}
```

## Troubleshooting

### Commands Not Found

**Problem:** `ios_system("mycommand")` returns 127 (command not found)

**Solutions:**
1. Ensure you've included the appropriate framework (e.g., `files.framework` for `ls`)
2. Verify command dictionaries are in your app's bundle resources
3. Check that frameworks are properly embedded and linked

### Framework Load Errors

**Problem:** App crashes with "dyld: Library not loaded: @rpath/openssl.framework/openssl"

**Cause:** You included `ssh_cmd.framework` or `curl_ios.framework` but didn't add their required dependencies.

**Solution:**

Download and add the missing dependencies:

```bash
# Run this script from the ios_system repository
./download-dependencies.sh
```

Or manually download:
- **openssl:** https://github.com/holzschu/openssl-apple/releases/download/v1.1.1w/openssl-dynamic.xcframework.zip
- **libssh2:** https://github.com/holzschu/libssh2-apple/releases/download/v1.11.0/libssh2-dynamic.xcframework.zip

Then add both XCFrameworks to your Xcode project with **"Embed & Sign"**.

**Alternative:** If you don't need SSH/network functionality, remove `ssh_cmd.framework` and `curl_ios.framework` from your project.

**Other dyld errors:**
1. Ensure frameworks are set to "Embed & Sign" in Xcode
2. Verify all framework dependencies are included
3. Check that `ios_system.framework` is included (always required)

### visionOS Compatibility Issues

**Problem:** Certain UI-based commands don't work on visionOS

**Solution:**
- The `open` command has limited functionality on visionOS
- Consider providing alternative UI for these operations
- Check command return codes and handle visionOS-specific cases

### File Access Denied

**Problem:** Commands fail with permission errors

**Solutions:**
1. iOS: Ensure you're only accessing sandbox directories (~/Documents/, ~/Library/, ~/tmp/)
2. Set HOME environment variable: `setenv("HOME", NSHomeDirectory(), 1)`
3. Mac Catalyst: Add necessary file access entitlements

## Example: Complete Integration

```swift
import UIKit
import ios_system

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {

        // Initialize ios_system
        initializeEnvironment()

        // Set environment variables
        let homeDir = NSHomeDirectory()
        setenv("HOME", homeDir, 1)
        setenv("TMPDIR", NSTemporaryDirectory(), 1)

        // Optional: Set custom streams for capturing output
        // setupCustomStreams()

        return true
    }
}

class TerminalViewController: UIViewController {
    @IBOutlet weak var outputTextView: UITextView!
    @IBOutlet weak var inputTextField: UITextField!

    override func viewDidLoad() {
        super.viewDidLoad()

        // Show available commands
        executeCommand("help")
    }

    func executeCommand(_ command: String) {
        let result = ios_system(command)

        if result == 0 {
            outputTextView.text += "✓ Command succeeded\n"
        } else {
            outputTextView.text += "✗ Command failed with code \(result)\n"
        }
    }

    @IBAction func runCommand(_ sender: Any) {
        guard let command = inputTextField.text, !command.isEmpty else { return }

        outputTextView.text += "> \(command)\n"
        executeCommand(command)
        inputTextField.text = ""
    }
}
```

## Minimum Deployment Targets

The frameworks built with this configuration support:

- **iOS:** 12.0+
- **iPadOS:** 12.0+
- **visionOS:** 1.0+
- **macOS (Catalyst):** 10.15+

## Additional Resources

- **Main Repository:** https://github.com/holzschu/ios_system
- **Documentation:** See README.md in the repository
- **Example Apps:** Check the examples/ directory for sample implementations
- **Issues:** Report problems at https://github.com/holzschu/ios_system/issues

## License

ios_system uses BSD 3-clause license. Individual commands retain their original licenses (mostly BSD, some MIT, GNU GPL for TeX-related tools). Check README.md for complete license information.
