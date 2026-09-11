# Xcode Project Setup for joe.framework

This document provides instructions for adding the joe framework target to the ios_system Xcode project.

## Prerequisites

All source code modifications have been completed:
- Thread-local storage added to global variables
- `main()` renamed to `joe_main()`
- iOS compatibility header created
- fork/exec operations disabled
- Terminal I/O redirected to thread-local streams
- autoconf.h created for iOS builds

## Adding the joe Target in Xcode

### Step 1: Create New Framework Target

1. Open `ios_system.xcodeproj` in Xcode
2. Click on the project in the navigator
3. Click the "+" button at the bottom of the targets list
4. Select "Framework" under iOS
5. Name it "joe"
6. Set Bundle Identifier to something like "com.holzschu.joe"
7. Click "Finish"

### Step 2: Configure Build Settings

Select the joe target and configure these settings:

**General:**
- Deployment Target: iOS 14.0
- Supported Destinations: iPhone, iPad, Mac (Designed for iPad)

**Build Settings:**
```
SUPPORTED_PLATFORMS = iphoneos iphonesimulator xros xrsimulator
SUPPORTS_MACCATALYST = YES
TARGETED_DEVICE_FAMILY = 1,2,7
IPHONEOS_DEPLOYMENT_TARGET = 14.0

FRAMEWORK_SEARCH_PATHS = $(inherited) $(PROJECT_DIR)/Frameworks

OTHER_CFLAGS = -Wno-shorten-64-to-32 -Wno-implicit-function-declaration -I$(PROJECT_DIR)/joe/joe

HEADER_SEARCH_PATHS = $(PROJECT_DIR)/joe/joe $(PROJECT_DIR)/ios_system
```

### Step 3: Add Source Files

Add all source files from `joe/joe/` to the joe target's "Compile Sources" build phase:

**C Source Files (60 files):**
```
EngNotation.c, b.c, blocks.c, builtin.c, builtins.c, bw.c, cclass.c,
charmap.c, cmd.c, colors.c, dir.c, frag.c, gettext.c, hash.c, help.c,
kbd.c, lattr.c, macro.c, main.c, menu.c, mmenu.c, mouse.c, options.c,
path.c, poshist.c, pw.c, queue.c, qw.c, rc.c, regex.c, scrn.c,
selinux.c, state.c, syntax.c, tab.c, termcap.c, tty.c, tw.c, ublock.c,
uedit.c, uerror.c, ufile.c, uformat.c, uisrch.c, umath.c, undo.c,
unicat-10.0.0.c, unicat-8.0.0.c, unicat-9.0.0.c, unicode.c, usearch.c,
ushell.c, utag.c, utf8.c, utils.c, va.c, vfile.c, vs.c, vt.c, w.c
```

To add these:
1. In Xcode, select the joe target
2. Go to Build Phases > Compile Sources
3. Click "+" and navigate to `joe/joe/`
4. Select all .c files and add them

### Step 4: Add Framework Dependencies

In Build Phases > Link Binary With Libraries, add:
- `ios_system.framework` (from project)
- `libncurses.tbd` (system library)

### Step 5: Configure Public Headers

1. Go to Build Phases > Headers
2. Add `joe_framework/joe.h` as Public header
3. Copy `joe_framework/Info.plist` to the joe target

### Step 6: Add App Resources (Optional)

For syntax highlighting and config files, add the processed `joerc`, `ftyperc`,
`joe/syntax/`, and `joe/colors/` to the consuming app's Copy Bundle Resources
phase. These application-owned files are not included in `joe.framework`.

### Step 7: Create Scheme

1. Go to Product > Scheme > Manage Schemes
2. Click "+" to add a new scheme
3. Select "joe" as the target
4. Name it "joe"

## Verification

After setup, try building the framework:

```bash
xcodebuild -project ios_system.xcodeproj -scheme joe -sdk iphoneos -configuration Release
```

## Building XCFramework

Once the Xcode target is configured, build the XCFramework:

```bash
swift run --package-path xcfs build joe
```

This will create `joe.xcframework` in `.build/joe/`.

## Troubleshooting

### Missing Headers
If you see header errors, ensure:
- `HEADER_SEARCH_PATHS` includes `$(PROJECT_DIR)/joe/joe`
- `ios_error.h` is accessible from ios_system.framework

### Undefined Symbols
If you see undefined symbol errors for ios_system functions:
- Ensure ios_system.framework is linked
- Check that ios_system is built first

### Thread-Local Storage Warnings
Some compilers may warn about `__thread` usage. These can be ignored or suppressed with `-Wno-unknown-attributes`.
