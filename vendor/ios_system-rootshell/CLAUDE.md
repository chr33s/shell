# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

ios_system is a drop-in replacement for `system()` calls in iOS applications, providing Unix-like command execution in a sandboxed environment. It enables executing shell commands, file operations, archive utilities, and network tools on iOS by replacing standard C library calls with thread-safe iOS-compatible implementations.

## Architecture

### Framework Structure

The project is organized as a collection of independent frameworks, each providing a category of Unix commands:

- **ios_system.framework**: Core system that loads and dispatches commands
- **files.framework**: File operations (cp, mv, rm, ls, chmod, chown, etc.)
- **shell.framework**: Shell utilities (echo, env, printenv, setenv, etc.)
- **text.framework**: Text processing (cat, grep, sed, wc, etc.)
- **tar.framework**: Archive operations (tar, gzip, compress, etc.)
- **awk.framework**: AWK text processing
- **curl_ios.framework**: Network operations (curl, scp, sftp via libssh2)
- **ssh_cmd.framework**: SSH client commands

Each framework is dynamically loaded when its commands are first called and can be released after execution to manage memory.

### Command Registration System

Commands are registered in two plist files:
- `Resources/commandDictionary.plist`: Standard commands
- `Resources/extraCommandsDictionary.plist`: Additional/optional commands

Each command entry specifies:
1. Framework containing the implementation
2. Main function name (e.g., `ls_main`)
3. getopt-style options string
4. Expected argument type (file/directory/no)

Apps must include these plists in "Copy Bundle Resources" build phase.

### Thread-Local Execution Model

ios_system uses thread-local storage for I/O streams to enable concurrent command execution:

```c
__thread FILE* thread_stdin;
__thread FILE* thread_stdout;
__thread FILE* thread_stderr;
__thread void* thread_context;
```

Each command executes in its own thread with isolated streams, allowing multiple simultaneous commands without conflicts.

### Session Management

Sessions track execution state per command chain:
- Current/previous directory
- Active thread IDs
- Environment variables
- Window size (COLUMNS/LINES)
- Command history

Use `ios_switchSession(sessionid)` to work with multiple independent command contexts.

### libc_replacement.c

This file intercepts standard C library calls and redirects them to thread-local versions:
- `printf` → writes to `thread_stdout`
- `fprintf` → routes STDOUT/STDERR to thread-local streams
- `exit` → `ios_exit` (returns from thread instead of terminating process)
- `system` → `ios_system`
- `popen` → `ios_popen`

Commands link against ios_system.framework to automatically use these replacements.

## Building

### Quick Build (Recommended)

```bash
swift run --package-path xcfs build
```

This builds all frameworks as XCFrameworks for iOS, iOS Simulator, and Catalyst. Output goes to `.build/` directory with zipped frameworks and checksums.

### Build Specific Frameworks

```bash
swift run --package-path xcfs build ios_system,awk,tar
```

### Xcode Build (Individual Frameworks)

```bash
xcodebuild -project ios_system.xcodeproj -scheme ios_system -sdk iphoneos -configuration Release
xcodebuild -project ios_system.xcodeproj -scheme files -sdk iphoneos -configuration Release
xcodebuild -project ios_system.xcodeproj -scheme tar -sdk iphoneos -configuration Release
# etc.
```

### Build All Targets

```bash
xcodebuild -project ios_system.xcodeproj -alltargets -sdk iphoneos -configuration Release -quiet
```

## Adding New Commands

When porting Unix utilities to ios_system:

1. **Modify main function**: Rename `main()` to `commandname_main(int argc, char *argv[])`

2. **Include ios_error.h**: This header provides iOS-safe replacements for system calls

3. **Link with ios_system.framework**: This automatically redirects standard library calls

4. **Replace isatty()**: Use `ios_isatty()` instead

5. **Make variables thread-safe**:
   - Global variables → `__thread` (thread-local)
   - Local static variables → keep `static` but ensure proper initialization

6. **Avoid forbidden APIs**: No `fork()`, `exec()`, `system()`, `isExecutableFileAtPath`, `access()` (sandbox violations)

7. **Handle I/O correctly**:
   - Output must go to `thread_stdout` (usually automatic via libc_replacement.c)
   - Input comes from `thread_stdin`
   - Some functions may need explicit redirection

8. **Initialize and cleanup**: Reset all state at entry, free all memory at exit (commands may run multiple times in same process)

9. **Add to dictionary**: Edit `Resources/extraCommandsDictionary.plist`:
   ```xml
   <key>yourcommand</key>
   <array>
     <string>framework_name.framework/framework_name</string>
     <string>yourcommand_main</string>
     <string>abc:def:g</string>  <!-- getopt options -->
     <string>file</string>         <!-- or directory/no -->
   </array>
   ```

## Integration Notes

### Basic Usage

```objective-c
#include "ios_system.h"
#define system ios_system

// Initialize environment variables
initializeEnvironment();

// Execute commands
ios_system("ls -la");
ios_system("grep pattern file.txt");

// Check if command exists
if (ios_executable("vim")) {
    ios_system("vim myfile.txt");
}
```

### Advanced Integration

```objective-c
// Set custom I/O streams
ios_setStreams(custom_stdin, custom_stdout, custom_stderr);

// Restrict filesystem access (sandbox within sandbox)
ios_setMiniRoot(@"/Users/username/Documents/sandbox");

// Add custom commands at runtime
replaceCommand(@"mycommand", my_command_main, false);

// Load command dictionaries
addCommandList(@"/path/to/custom_commands.plist");
```

### iOS Filesystem Limitations

iOS restricts writes to:
- `~/Documents/` (user visible files)
- `~/Library/` (app support files)
- `~/tmp/` (temporary files)

Configuration files typically in `$HOME` must be redirected via environment variables:
```objective-c
setenv("HOME", "~/Documents/", 1);
setenv("PYTHONHOME", "~/Library/", 1);
setenv("SSH_HOME", "~/Documents/", 1);
setenv("CURL_HOME", "~/Documents/", 1);
```

## Swift Package Manager

The repository is consumable as a Swift Package with binary XCFramework targets. Add to Package.swift:

```swift
dependencies: [
    .package(url: "https://github.com/holzschu/ios_system", from: "3.0.0")
]
```

Binary frameworks are downloaded from GitHub releases with checksums verified.

## CI/CD

GitHub Actions workflow (`.github/workflows/build.yml`) builds and publishes releases:
- Triggers on version tags (`v*`)
- Builds all frameworks via `swift run --package-path xcfs build`
- Creates release with zipped XCFrameworks and checksums
- Uploads `ios_error.h` and command dictionaries

## License Notes

ios_system uses BSD 3-clause license. Individual commands retain their original licenses (mostly BSD, some MIT, GNU GPL for TeX-related tools). Check README.md for full license details of each component.
