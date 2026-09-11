# Joe Editor Integration Guide for ios_system

This document describes how to integrate the Joe text editor framework into your iOS, Mac Catalyst, or visionOS application.

## Overview

Joe (Joe's Own Editor) is a full-featured terminal text editor that has been adapted to run within the ios_system framework. It provides syntax highlighting, multiple buffers, search/replace, and many other editing features.

## First-Time Setup

Your app must bundle joe's resource files and copy them to a writable location
on first launch. The rootshell app keeps its copies under `Resources/joe`.
These files are deliberately not duplicated inside `joe.framework`.

### Resource Files

The app resource directory must contain:
- `joerc` - Main configuration file
- `ftyperc` - File type and syntax selection rules
- `syntax/` - Syntax highlighting definitions (*.jsf files)
- `colors/` - Color scheme definitions

### Copying Resources

**Swift Example:**

```swift
import Foundation

func setupJoeResources() {
    let fileManager = FileManager.default
    let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    let joeHomeURL = documentsURL.appendingPathComponent(".joe")

    // Create .joe directory if needed
    if !fileManager.fileExists(atPath: joeHomeURL.path) {
        try? fileManager.createDirectory(at: joeHomeURL, withIntermediateDirectories: true)
    }

    // Copy joerc if not present
    let joercDest = documentsURL.appendingPathComponent(".joerc")
    if !fileManager.fileExists(atPath: joercDest.path) {
        if let joercSource = Bundle.main.url(
            forResource: "joerc",
            withExtension: nil,
            subdirectory: "joe"
        ) {
            try? fileManager.copyItem(at: joercSource, to: joercDest)
        }
    }

    // Copy syntax directory if not present
    let syntaxDest = joeHomeURL.appendingPathComponent("syntax")
    if !fileManager.fileExists(atPath: syntaxDest.path) {
        if let syntaxSource = Bundle.main.url(
            forResource: "syntax",
            withExtension: nil,
            subdirectory: "joe"
        ) {
            try? fileManager.copyItem(at: syntaxSource, to: syntaxDest)
        }
    }

    // Copy colors directory if not present
    let colorsDest = joeHomeURL.appendingPathComponent("colors")
    if !fileManager.fileExists(atPath: colorsDest.path) {
        if let colorsSource = Bundle.main.url(
            forResource: "colors",
            withExtension: nil,
            subdirectory: "joe"
        ) {
            try? fileManager.copyItem(at: colorsSource, to: colorsDest)
        }
    }

    // Copy file type rules if not present
    let ftypercDest = joeHomeURL.appendingPathComponent("ftyperc")
    if !fileManager.fileExists(atPath: ftypercDest.path) {
        if let ftypercSource = Bundle.main.url(
            forResource: "ftyperc",
            withExtension: nil,
            subdirectory: "joe"
        ) {
            try? fileManager.copyItem(at: ftypercSource, to: ftypercDest)
        }
    }
}
```

**Objective-C Example:**

```objc
#import <Foundation/Foundation.h>

- (void)setupJoeResources {
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSURL *documentsURL = [[fileManager URLsForDirectory:NSDocumentDirectory
                                               inDomains:NSUserDomainMask] firstObject];
    NSURL *joeHomeURL = [documentsURL URLByAppendingPathComponent:@".joe"];

    // Create .joe directory if needed
    if (![fileManager fileExistsAtPath:joeHomeURL.path]) {
        [fileManager createDirectoryAtURL:joeHomeURL
              withIntermediateDirectories:YES
                               attributes:nil
                                    error:nil];
    }

    // Copy joerc if not present
    NSURL *joercDest = [documentsURL URLByAppendingPathComponent:@".joerc"];
    if (![fileManager fileExistsAtPath:joercDest.path]) {
        NSURL *joercSource = [[NSBundle mainBundle] URLForResource:@"joerc"
                                                     withExtension:nil
                                                      subdirectory:@"joe"];
        if (joercSource) {
            [fileManager copyItemAtURL:joercSource toURL:joercDest error:nil];
        }
    }

    // Copy ftyperc, syntax/, and colors/ from the same app resource directory.
}
```

## Required Environment Variables

Before invoking joe, set these environment variables:

| Variable | Description | Example Value |
|----------|-------------|---------------|
| `HOME` | User's home directory | `~/Documents` |
| `TERM` | Terminal type | `xterm-256color` |
| `JOE_HOME` | Joe configuration directory (optional) | `~/Documents/.joe` |

**Example:**

```swift
setenv("HOME", NSHomeDirectory() + "/Documents", 1)
setenv("TERM", "xterm-256color", 1)
setenv("JOE_HOME", NSHomeDirectory() + "/Documents/.joe", 1)
```

## Directory Structure

After setup, your app's Documents directory should contain:

```
~/Documents/
  ├── .joerc              # Main configuration
  └── .joe/
      ├── ftyperc         # File type and syntax selection rules
      ├── syntax/         # Syntax highlighting definitions
      │   ├── c.jsf
      │   ├── python.jsf
      │   └── ...
      └── colors/         # Color schemes
          └── ...
```

## Invoking Joe

Joe is invoked through ios_system like any other command:

```swift
import ios_system

// Open joe with a file
ios_system("joe ~/Documents/myfile.txt")

// Open joe with no file (empty buffer)
ios_system("joe")
```

## Terminal Requirements

Joe requires a terminal emulator that supports:
- ANSI escape sequences for cursor positioning and colors
- Window size reporting (TIOCGWINSZ or COLUMNS/LINES environment variables)
- Raw input mode for keyboard handling

Set terminal dimensions via environment variables if not auto-detected:

```swift
setenv("LINES", "24", 1)
setenv("COLUMNS", "80", 1)
```

## Known Limitations

The iOS version of joe has these limitations due to iOS sandbox restrictions:

### Shell Commands Not Available

The following features are disabled because they require fork/exec:

- **Shell filter commands** - Piping buffer content through external commands (e.g., `|sort`, `|grep`)
- **External command execution** - Running arbitrary shell commands from within joe
- **Compile/make integration** - Building from within the editor

When a user attempts to use these features, they will see the message:
> "Shell commands are not available on iOS"

### Other Limitations

- **No SIGALRM timers** - Some timer-based features may not work as expected
- **Limited signal handling** - iOS signal support differs from desktop Unix
- **File access restricted** - Only files within the app's sandbox are accessible

## Customizing Joe

Users can customize joe by editing the `joerc` file in `~/.joe/`. Common customizations:

- Key bindings
- Tab width and indentation
- Syntax highlighting colors
- Editor behavior (autowrap, autoindent, etc.)

Refer to joe's documentation for the full configuration options.

## Troubleshooting

### Joe won't start

1. Verify joerc exists at the expected location
2. Check that TERM environment variable is set
3. Ensure the terminal emulator supports required escape sequences

### No syntax highlighting

1. Verify the `syntax/` directory was copied correctly
2. Check that syntax files (*.jsf) are present
3. Ensure file extensions match syntax definitions in joerc

### Display issues

1. Check LINES and COLUMNS environment variables
2. Verify terminal supports ANSI escape codes
3. Try setting `TERM=xterm` if `xterm-256color` causes issues

## Version Information

This integration is based on joe (Joe's Own Editor) adapted for ios_system.

- ios_system framework required
- Target platforms: iOS 14.0+, Mac Catalyst, visionOS
