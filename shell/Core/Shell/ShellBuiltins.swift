#if !targetEnvironment(macCatalyst)

import Foundation

/// Built-in shell commands that must be handled by the interpreter
/// (they affect interpreter state or can't be delegated to ios_system).
///
/// Each builtin is a function: `(args, environment, interpreter) throws -> Int32`
nonisolated enum ShellBuiltins {
    typealias Builtin = ([String], ShellEnvironment, ShellInterpreter) throws -> Int32

    /// Look up a builtin by command name. Returns nil if not a builtin.
    static func lookup(_ name: String) -> Builtin? {
        switch name {
        case "true":       return builtinTrue
        case "false":      return builtinFalse
        case ":":          return builtinColon
        case "echo":       return builtinEcho
        case "printf":     return builtinPrintf
        case "test":       return builtinTest
        case "[":          return builtinBracket
        case "export":     return builtinExport
        case "unset":      return builtinUnset
        case "local":      return builtinLocal
        case "return":     return builtinReturn
        case "break":      return builtinBreak
        case "continue":   return builtinContinue
        case "exit":       return builtinExit
        case "shift":      return builtinShift
        case "set":        return builtinSet
        case "read":       return builtinRead
        case "sleep":      return builtinSleep
        case "trap":       return builtinTrap
        case "eval":       return builtinEval
        case "source", ".": return builtinSource
        case "type":       return builtinType
        case "let":        return builtinLet
        case "cd":         return builtinCd
        case "pwd":        return builtinPwd
        case "jobs":       return builtinJobs
        case "wait":       return builtinWait
        default:           return nil
        }
    }

    /// Builtins that must go through the shell interpreter because ios_system
    /// doesn't provide them. Commands like `cd`, `echo`, `export` are handled by
    /// ios_system natively, so they're excluded.
    private static let interpreterOnlyBuiltins: Set<String> = [
        "sleep", "printf", "test", "[", "read", "true", "false", ":",
        "local", "return", "break", "continue", "shift", "set",
        "trap", "eval", "type", "let", "jobs", "wait"
    ]

    /// Check if a command name is a builtin that only works through the interpreter
    /// (not available via ios_system).
    static func isInterpreterOnly(_ name: String) -> Bool {
        interpreterOnlyBuiltins.contains(name)
    }

    // MARK: - Simple Builtins

    static func builtinTrue(_: [String], _ env: ShellEnvironment, _: ShellInterpreter) -> Int32 { 0 }
    static func builtinFalse(_: [String], _ env: ShellEnvironment, _: ShellInterpreter) -> Int32 { 1 }
    static func builtinColon(_: [String], _ env: ShellEnvironment, _: ShellInterpreter) -> Int32 { 0 }

    // MARK: - echo

    static func builtinEcho(_ args: [String], _ env: ShellEnvironment,
                             _ interp: ShellInterpreter) -> Int32 {
        var newline = true
        var interpretEscapes = false
        var startIdx = 0

        // Parse flags
        while startIdx < args.count {
            let arg = args[startIdx]
            if arg == "-n" {
                newline = false
                startIdx += 1
            } else if arg == "-e" {
                interpretEscapes = true
                startIdx += 1
            } else if arg == "-E" {
                interpretEscapes = false
                startIdx += 1
            } else if arg == "-ne" || arg == "-en" {
                newline = false
                interpretEscapes = true
                startIdx += 1
            } else {
                break
            }
        }

        var output = args[startIdx...].joined(separator: " ")

        if interpretEscapes {
            let (processed, stopped) = processEscapesWithStop(output)
            output = processed
            if stopped { newline = false }
        }

        if newline {
            interp.writeLine(output)
        } else {
            interp.writeString(output)
        }

        return 0
    }

    /// Process C-style escape sequences in a string (index-based so octal/hex
    /// sequences can be scanned with lookahead). Returns the processed text
    /// and whether a `\c` (stop output) was seen.
    static func processEscapes(_ s: String) -> String {
        processEscapesWithStop(s).0
    }

    static func processEscapesWithStop(_ s: String) -> (String, Bool) {
        let chars = Array(s)
        var result = ""
        var i = 0
        while i < chars.count {
            guard chars[i] == "\\", i + 1 < chars.count else {
                result.append(chars[i])
                i += 1
                continue
            }
            let next = chars[i + 1]
            i += 2
            switch next {
            case "n":  result.append("\n")
            case "t":  result.append("\t")
            case "r":  result.append("\r")
            case "\\": result.append("\\")
            case "a":  result.append("\u{07}") // bell
            case "b":  result.append("\u{08}") // backspace
            case "f":  result.append("\u{0C}") // form feed
            case "v":  result.append("\u{0B}") // vertical tab
            case "e":  result.append("\u{1B}") // escape
            case "c":  return (result, true)   // stop all further output
            case "0":
                // Octal: \0NNN (up to 3 digits)
                var octal = ""
                while octal.count < 3, i < chars.count, ("0"..."7").contains(chars[i]) {
                    octal.append(chars[i])
                    i += 1
                }
                if octal.isEmpty {
                    result.append("\0")
                } else if let val = UInt32(octal, radix: 8), let scalar = UnicodeScalar(val) {
                    result.append(Character(scalar))
                }
            case "x":
                // Hex: \xHH (up to 2 digits)
                var hex = ""
                while hex.count < 2, i < chars.count, chars[i].isHexDigit {
                    hex.append(chars[i])
                    i += 1
                }
                if hex.isEmpty {
                    result.append("\\x")
                } else if let val = UInt32(hex, radix: 16), let scalar = UnicodeScalar(val) {
                    result.append(Character(scalar))
                }
            default:
                result.append("\\")
                result.append(next)
            }
        }
        return (result, false)
    }

    // MARK: - printf

    static func builtinPrintf(_ args: [String], _ env: ShellEnvironment,
                               _ interp: ShellInterpreter) -> Int32 {
        guard let format = args.first else {
            interp.writeLine("printf: usage: printf format [arguments]")
            return 1
        }

        let fmtArgs = Array(args.dropFirst())
        let output = formatPrintf(format, args: fmtArgs)
        interp.writeString(output)
        return 0
    }

    /// printf with `%[flags][width][.precision]conversion` support for
    /// s c b d i u o x X e E f g G %. POSIX format reuse: the format string
    /// repeats until all arguments are consumed.
    private static func formatPrintf(_ format: String, args: [String]) -> String {
        var result = ""
        var argIdx = 0

        repeat {
            let consumedBefore = argIdx
            formatPrintfOnce(format, args: args, argIdx: &argIdx, into: &result)
            // Reuse the format only while it consumes arguments (guards
            // against infinite loops on argument-free formats).
            if argIdx == consumedBefore { break }
        } while argIdx < args.count

        return result
    }

    private static func formatPrintfOnce(_ format: String, args: [String],
                                         argIdx: inout Int, into result: inout String) {
        let chars = Array(format)
        var i = 0

        func nextArg() -> String {
            defer { argIdx += 1 }
            return argIdx < args.count ? args[argIdx] : ""
        }

        while i < chars.count {
            let c = chars[i]

            if c == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                switch next {
                case "n": result.append("\n"); i += 2
                case "t": result.append("\t"); i += 2
                case "r": result.append("\r"); i += 2
                case "\\": result.append("\\"); i += 2
                case "a": result.append("\u{07}"); i += 2
                case "b": result.append("\u{08}"); i += 2
                case "f": result.append("\u{0C}"); i += 2
                case "v": result.append("\u{0B}"); i += 2
                case "e": result.append("\u{1B}"); i += 2
                case "0"..."7":
                    // printf octal is \NNN (no leading 0 required)
                    var octal = ""
                    var j = i + 1
                    while octal.count < 3, j < chars.count, ("0"..."7").contains(chars[j]) {
                        octal.append(chars[j])
                        j += 1
                    }
                    if let v = UInt32(octal, radix: 8), let scalar = UnicodeScalar(v) {
                        result.append(Character(scalar))
                    }
                    i = j
                case "x":
                    var hex = ""
                    var j = i + 2
                    while hex.count < 2, j < chars.count, chars[j].isHexDigit {
                        hex.append(chars[j])
                        j += 1
                    }
                    if hex.isEmpty {
                        result.append("\\x")
                    } else if let v = UInt32(hex, radix: 16), let scalar = UnicodeScalar(v) {
                        result.append(Character(scalar))
                    }
                    i = j
                default:
                    result.append("\\")
                    result.append(next)
                    i += 2
                }
                continue
            }

            guard c == "%" else {
                result.append(c)
                i += 1
                continue
            }
            i += 1
            guard i < chars.count else {
                result.append("%")
                break
            }

            if chars[i] == "%" {
                result.append("%")
                i += 1
                continue
            }

            // flags
            var flagMinus = false, flagZero = false, flagPlus = false, flagSpace = false, flagHash = false
            var parsingFlags = true
            while parsingFlags, i < chars.count {
                switch chars[i] {
                case "-": flagMinus = true; i += 1
                case "0": flagZero = true; i += 1
                case "+": flagPlus = true; i += 1
                case " ": flagSpace = true; i += 1
                case "#": flagHash = true; i += 1
                default: parsingFlags = false
                }
            }

            // width
            var width = 0
            var hasWidth = false
            if i < chars.count, chars[i] == "*" {
                width = Int(nextArg()) ?? 0
                hasWidth = true
                i += 1
            } else {
                while i < chars.count, chars[i].isNumber {
                    width = width * 10 + Int(String(chars[i]))!
                    hasWidth = true
                    i += 1
                }
            }

            // precision
            var precision: Int?
            if i < chars.count, chars[i] == "." {
                i += 1
                if i < chars.count, chars[i] == "*" {
                    precision = Int(nextArg()) ?? 0
                    i += 1
                } else {
                    var p = 0
                    while i < chars.count, chars[i].isNumber {
                        p = p * 10 + Int(String(chars[i]))!
                        i += 1
                    }
                    precision = p
                }
            }

            guard i < chars.count else {
                result.append("%")
                break
            }
            let conv = chars[i]
            i += 1

            // Assemble a C format spec with the parsed pieces, converting the
            // shell argument to the right Swift type. User strings are never
            // passed as the format itself.
            var spec = "%"
            if flagMinus { spec += "-" }
            if flagPlus { spec += "+" }
            if flagSpace { spec += " " }
            if flagHash { spec += "#" }
            if flagZero { spec += "0" }
            if hasWidth { spec += String(width) }
            if let precision { spec += ".\(precision)" }

            switch conv {
            case "s":
                var s = nextArg()
                if let precision, precision < s.count { s = String(s.prefix(precision)) }
                result.append(pad(s, width: hasWidth ? width : 0, leftAlign: flagMinus))
            case "c":
                let s = nextArg()
                result.append(pad(s.isEmpty ? "" : String(s.first!),
                                  width: hasWidth ? width : 0, leftAlign: flagMinus))
            case "b":
                // %b: process escape sequences in the argument
                let (processed, _) = processEscapesWithStop(nextArg())
                result.append(pad(processed, width: hasWidth ? width : 0, leftAlign: flagMinus))
            case "d", "i":
                result.append(String(format: spec + "ld", parseInt(nextArg())))
            case "u":
                result.append(String(format: spec + "lu", UInt(bitPattern: Int(parseInt(nextArg())))))
            case "o":
                result.append(String(format: spec + "lo", parseInt(nextArg())))
            case "x":
                result.append(String(format: spec + "lx", parseInt(nextArg())))
            case "X":
                result.append(String(format: spec + "lX", parseInt(nextArg())))
            case "e", "E", "f", "F", "g", "G":
                result.append(String(format: spec + String(conv), Double(nextArg()) ?? 0))
            default:
                // Unknown conversion: emit verbatim
                result.append(spec)
                result.append(conv)
            }
        }
    }

    private static func parseInt(_ s: String) -> Int {
        // Accept leading quotes for char codes ('A → 65) per POSIX
        if s.hasPrefix("'") || s.hasPrefix("\""), s.count >= 2 {
            return Int(Array(s.unicodeScalars)[1].value)
        }
        if s.hasPrefix("0x") || s.hasPrefix("0X") {
            return Int(s.dropFirst(2), radix: 16) ?? 0
        }
        if s.hasPrefix("0"), s.count > 1, s.dropFirst().allSatisfy({ ("0"..."7").contains($0) }) {
            return Int(s.dropFirst(), radix: 8) ?? 0
        }
        return Int(s) ?? 0
    }

    private static func pad(_ s: String, width: Int, leftAlign: Bool) -> String {
        guard width > s.count else { return s }
        let padding = String(repeating: " ", count: width - s.count)
        return leftAlign ? s + padding : padding + s
    }

    // MARK: - test / [

    static func builtinTest(_ args: [String], _ env: ShellEnvironment,
                             _ interp: ShellInterpreter) throws -> Int32 {
        try interp.checkCancelled()
        return evaluateTestExpression(args) ? 0 : 1
    }

    static func builtinBracket(_ args: [String], _ env: ShellEnvironment,
                                _ interp: ShellInterpreter) throws -> Int32 {
        try interp.checkCancelled()
        // Remove trailing ] if present
        var testArgs = args
        if testArgs.last == "]" {
            testArgs.removeLast()
        }
        return evaluateTestExpression(testArgs) ? 0 : 1
    }

    /// Evaluate a `test` expression. Also reused by the `[[ ]]` evaluator for
    /// unary and non-pattern binary operators.
    static func evaluateTestExpression(_ args: [String]) -> Bool {
        if args.isEmpty { return false }

        // Unary: ! EXPR
        if args.first == "!" {
            return !evaluateTestExpression(Array(args.dropFirst()))
        }

        // Single arg: true if non-empty
        if args.count == 1 {
            return !args[0].isEmpty
        }

        // Binary with logical operators: EXPR -a EXPR, EXPR -o EXPR
        if let idx = args.firstIndex(of: "-o") {
            let left = evaluateTestExpression(Array(args[..<idx]))
            let right = evaluateTestExpression(Array(args[(idx + 1)...]))
            return left || right
        }
        if let idx = args.firstIndex(of: "-a") {
            let left = evaluateTestExpression(Array(args[..<idx]))
            let right = evaluateTestExpression(Array(args[(idx + 1)...]))
            return left && right
        }

        // Two args: unary operators
        if args.count == 2 {
            let op = args[0]
            let operand = args[1]

            switch op {
            case "-z": return operand.isEmpty
            case "-n": return !operand.isEmpty
            case "-e": return FileManager.default.fileExists(atPath: operand)
            case "-f":
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: operand, isDirectory: &isDir) && !isDir.boolValue
            case "-d":
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: operand, isDirectory: &isDir) && isDir.boolValue
            case "-r": return FileManager.default.isReadableFile(atPath: operand)
            case "-w": return FileManager.default.isWritableFile(atPath: operand)
            case "-x": return FileManager.default.isExecutableFile(atPath: operand)
            case "-s":
                if let attrs = try? FileManager.default.attributesOfItem(atPath: operand),
                   let size = attrs[.size] as? Int64 {
                    return size > 0
                }
                return false
            case "-L", "-h":
                // Symbolic link test
                if let attrs = try? FileManager.default.attributesOfItem(atPath: operand),
                   let type = attrs[.type] as? FileAttributeType {
                    return type == .typeSymbolicLink
                }
                return false
            default:
                return false
            }
        }

        // Three args: binary operators
        if args.count == 3 {
            let left = args[0]
            let op = args[1]
            let right = args[2]

            switch op {
            // String comparisons
            case "=", "==": return left == right
            case "!=": return left != right

            // Integer comparisons
            case "-eq": return (Int(left) ?? 0) == (Int(right) ?? 0)
            case "-ne": return (Int(left) ?? 0) != (Int(right) ?? 0)
            case "-lt": return (Int(left) ?? 0) < (Int(right) ?? 0)
            case "-gt": return (Int(left) ?? 0) > (Int(right) ?? 0)
            case "-le": return (Int(left) ?? 0) <= (Int(right) ?? 0)
            case "-ge": return (Int(left) ?? 0) >= (Int(right) ?? 0)

            // File comparisons
            case "-nt": return fileNewer(left, than: right)
            case "-ot": return fileNewer(right, than: left)

            default: return false
            }
        }

        return false
    }

    private static func fileNewer(_ a: String, than b: String) -> Bool {
        guard let aAttrs = try? FileManager.default.attributesOfItem(atPath: a),
              let bAttrs = try? FileManager.default.attributesOfItem(atPath: b),
              let aDate = aAttrs[.modificationDate] as? Date,
              let bDate = bAttrs[.modificationDate] as? Date else {
            return false
        }
        return aDate > bDate
    }

    // MARK: - export

    static func builtinExport(_ args: [String], _ env: ShellEnvironment,
                               _ interp: ShellInterpreter) -> Int32 {
        for arg in args {
            if arg == "-p" {
                let exported = env.snapshotExportedState()
                for name in exported.names.sorted() {
                    let value = exported.values[name] ?? env.getVariable(name) ?? ""
                    let escaped = value.replacingOccurrences(of: "\"", with: "\\\"")
                    interp.writeLine("export \(name)=\"\(escaped)\"")
                }
                continue
            }
            if let eqIdx = arg.firstIndex(of: "=") {
                let name = String(arg[arg.startIndex..<eqIdx])
                let value = String(arg[arg.index(after: eqIdx)...])
                env.exportVariable(name, value: value)
            } else {
                // Export existing variable
                env.exportVariable(arg)
            }
        }
        return 0
    }

    // MARK: - unset

    static func builtinUnset(_ args: [String], _ env: ShellEnvironment,
                              _ interp: ShellInterpreter) -> Int32 {
        var unsetFunctions = false
        var names: [String] = []

        for arg in args {
            if arg == "-f" {
                unsetFunctions = true
            } else if arg == "-v" {
                unsetFunctions = false
            } else {
                names.append(arg)
            }
        }

        for name in names {
            if unsetFunctions {
                env.unsetFunction(name)
            } else {
                env.unsetVariable(name)
            }
        }
        return 0
    }

    // MARK: - local

    static func builtinLocal(_ args: [String], _ env: ShellEnvironment,
                              _ interp: ShellInterpreter) -> Int32 {
        for arg in args {
            if let eqIdx = arg.firstIndex(of: "=") {
                let name = String(arg[arg.startIndex..<eqIdx])
                let value = String(arg[arg.index(after: eqIdx)...])
                env.declareLocal(name, value: value)
            } else {
                env.declareLocal(arg, value: nil)
            }
        }
        return 0
    }

    // MARK: - Control Flow Builtins

    static func builtinReturn(_ args: [String], _ env: ShellEnvironment,
                               _ interp: ShellInterpreter) throws -> Int32 {
        let code = args.first.flatMap { Int32($0) } ?? env.getLastExitCode()
        throw ShellError.returnSignal(code)
    }

    static func builtinBreak(_ args: [String], _ env: ShellEnvironment,
                              _ interp: ShellInterpreter) throws -> Int32 {
        let levels = args.first.flatMap { Int($0) } ?? 1
        throw ShellError.breakSignal(max(1, levels))
    }

    static func builtinContinue(_ args: [String], _ env: ShellEnvironment,
                                 _ interp: ShellInterpreter) throws -> Int32 {
        let levels = args.first.flatMap { Int($0) } ?? 1
        throw ShellError.continueSignal(max(1, levels))
    }

    static func builtinExit(_ args: [String], _ env: ShellEnvironment,
                             _ interp: ShellInterpreter) throws -> Int32 {
        let code = args.first.flatMap { Int32($0) } ?? env.getLastExitCode()
        throw ShellError.exitSignal(code)
    }

    // MARK: - shift

    static func builtinShift(_ args: [String], _ env: ShellEnvironment,
                              _ interp: ShellInterpreter) -> Int32 {
        let n = args.first.flatMap { Int($0) } ?? 1
        env.shiftParams(n)
        return 0
    }

    // MARK: - set

    static func builtinSet(_ args: [String], _ env: ShellEnvironment,
                            _ interp: ShellInterpreter) -> Int32 {
        if args.isEmpty {
            // `set` with no args: print shell variables
            for (name, value) in env.snapshotVariables().sorted(by: { $0.key < $1.key }) {
                interp.writeLine("\(name)=\(value)")
            }
            return 0
        }

        var i = 0
        while i < args.count {
            let arg = args[i]

            // `set -- arg1 arg2 ...`: remaining args become positional params
            if arg == "--" {
                env.setPositionalParams(Array(args[(i + 1)...]), scriptName: env.getScriptName())
                return 0
            }

            guard (arg.hasPrefix("-") || arg.hasPrefix("+")), arg.count >= 2 else {
                // First non-option argument: it and the rest become positionals
                env.setPositionalParams(Array(args[i...]), scriptName: env.getScriptName())
                return 0
            }

            let enable = arg.hasPrefix("-")

            if arg == "-o" || arg == "+o" {
                i += 1
                guard i < args.count else {
                    // `set -o` alone: list option states
                    let opts = env.options
                    interp.writeLine("errexit        \(opts.errexit ? "on" : "off")")
                    interp.writeLine("nounset        \(opts.nounset ? "on" : "off")")
                    interp.writeLine("xtrace         \(opts.xtrace ? "on" : "off")")
                    interp.writeLine("pipefail       \(opts.pipefail ? "on" : "off")")
                    return 0
                }
                switch args[i] {
                case "errexit":  env.updateOptions { $0.errexit = enable }
                case "nounset":  env.updateOptions { $0.nounset = enable }
                case "xtrace":   env.updateOptions { $0.xtrace = enable }
                case "pipefail": env.updateOptions { $0.pipefail = enable }
                default:
                    interp.writeLine("sh: set: \(args[i]): invalid option name")
                    return 2
                }
                i += 1
                continue
            }

            for flag in arg.dropFirst() {
                switch flag {
                case "e": env.updateOptions { $0.errexit = enable }
                case "u": env.updateOptions { $0.nounset = enable }
                case "x": env.updateOptions { $0.xtrace = enable }
                // Recognized POSIX options we don't implement — accept
                // silently so `set -f` etc. don't abort real scripts.
                case "a", "b", "C", "f", "h", "m", "n", "v":
                    break
                default:
                    interp.writeLine("sh: set: \(arg.hasPrefix("-") ? "-" : "+")\(flag): invalid option")
                    return 2
                }
            }
            i += 1
        }
        return 0
    }

    // MARK: - read

    static func builtinRead(_ args: [String], _ env: ShellEnvironment,
                             _ interp: ShellInterpreter) throws -> Int32 {
        try interp.checkCancelled()

        var prompt: String?
        var silent = false
        var varNames: [String] = []
        var i = 0

        // Parse options
        while i < args.count {
            let arg = args[i]
            if arg == "-p" && i + 1 < args.count {
                i += 1
                prompt = args[i]
            } else if arg == "-s" {
                silent = true
            } else if arg == "-r" {
                // Raw mode (don't interpret backslashes) — default for us
            } else if arg.hasPrefix("-") {
                // Skip unknown options
            } else {
                varNames.append(arg)
            }
            i += 1
        }

        // Default variable name is REPLY
        if varNames.isEmpty {
            varNames = ["REPLY"]
        }

        // Read a line from the terminal (pass silent flag for echo suppression)
        guard let line = interp.readLine(prompt, silent) else {
            // EOF or cancelled
            return 1
        }

        // Split line and assign to variables
        if varNames.count == 1 {
            env.setVariable(varNames[0], value: line)
        } else {
            let words = line.split(separator: " ", maxSplits: varNames.count - 1,
                                   omittingEmptySubsequences: false)
            for (idx, name) in varNames.enumerated() {
                if idx < words.count {
                    env.setVariable(name, value: String(words[idx]))
                } else {
                    env.setVariable(name, value: "")
                }
            }
        }

        return 0
    }

    // MARK: - sleep

    /// Interruptible sleep command. Checks cancellation every 100ms.
    /// Supports decimal seconds: `sleep 0.5`, `sleep 2.5`
    static func builtinSleep(_ args: [String], _ env: ShellEnvironment,
                              _ interp: ShellInterpreter) throws -> Int32 {
        guard let arg = args.first else {
            interp.writeLine("sleep: missing operand")
            return 1
        }

        guard let seconds = Double(arg), seconds >= 0 else {
            interp.writeLine("sleep: invalid time interval '\(arg)'")
            return 1
        }

        let totalMs = Int(seconds * 1000)
        var elapsed = 0
        let checkInterval = 100 // ms

        while elapsed < totalMs {
            try interp.checkCancelled()
            let remaining = min(checkInterval, totalMs - elapsed)
            Thread.sleep(forTimeInterval: Double(remaining) / 1000.0)
            elapsed += remaining
        }

        return 0
    }

    // MARK: - trap

    static func builtinTrap(_ args: [String], _ env: ShellEnvironment,
                             _ interp: ShellInterpreter) throws -> Int32 {
        if args.isEmpty {
            // List registered traps
            let names: [TrapRegistry.Signal: String] = [.int: "INT", .exit: "EXIT", .err: "ERR"]
            for name in interp.trapRegistry.snapshot().keys.compactMap({ names[$0] }).sorted() {
                interp.writeLine("trap -- (handler) \(name)")
            }
            return 0
        }

        if args.count == 1 {
            // `trap ''` — clear all traps? Or single signal name to reset?
            return 0
        }

        let action = args[0]
        let signals = Array(args.dropFirst())

        for sigName in signals {
            guard let sig = TrapRegistry.parseSignal(sigName) else {
                interp.writeLine("trap: \(sigName): invalid signal specification")
                continue
            }

            if action.isEmpty || action == "-" {
                // Reset to default
                interp.trapRegistry.register(signal: sig, action: nil)
            } else {
                // Parse the action as a shell command
                let tokenizer = ShellTokenizer(source: action)
                let parser = ShellParser(tokenizer: tokenizer)
                if let cmd = try? parser.parse() {
                    interp.trapRegistry.register(signal: sig, action: cmd)
                }
            }
        }

        return 0
    }

    // MARK: - eval

    static func builtinEval(_ args: [String], _ env: ShellEnvironment,
                             _ interp: ShellInterpreter) throws -> Int32 {
        let command = args.joined(separator: " ")
        guard !command.isEmpty else { return 0 }

        let tokenizer = ShellTokenizer(source: command)
        let parser = ShellParser(tokenizer: tokenizer)
        let ast = try parser.parse()
        return try interp.execute(ast)
    }

    // MARK: - source / .

    static func builtinSource(_ args: [String], _ env: ShellEnvironment,
                               _ interp: ShellInterpreter) throws -> Int32 {
        guard let path = args.first else {
            interp.writeLine("source: filename argument required")
            return 1
        }

        let resolvedPath = env.resolvePath(path)

        guard let content = try? String(contentsOfFile: resolvedPath, encoding: .utf8) else {
            interp.writeLine("source: \(path): No such file or directory")
            return 1
        }

        let tokenizer = ShellTokenizer(source: content)
        let parser = ShellParser(tokenizer: tokenizer)
        let ast = try parser.parse()

        // Source runs in the current environment (not a subshell)
        return try interp.execute(ast)
    }

    // MARK: - type

    static func builtinType(_ args: [String], _ env: ShellEnvironment,
                             _ interp: ShellInterpreter) -> Int32 {
        var exitCode: Int32 = 0

        for name in args {
            if lookup(name) != nil {
                interp.writeLine("\(name) is a shell builtin")
            } else if env.getFunction(name) != nil {
                interp.writeLine("\(name) is a function")
            } else if ios_executable(name) != 0 {
                interp.writeLine("\(name) is an external command")
            } else {
                interp.writeLine("type: \(name): not found")
                exitCode = 1
            }
        }

        return exitCode
    }

    // MARK: - let

    static func builtinLet(_ args: [String], _ env: ShellEnvironment,
                            _ interp: ShellInterpreter) throws -> Int32 {
        var result: Int64 = 0
        for arg in args {
            result = try ShellArithmeticEvaluator.evaluate(arg, environment: env)
        }
        return result == 0 ? 1 : 0
    }

    // MARK: - cd

    static func builtinCd(_ args: [String], _ env: ShellEnvironment,
                           _ interp: ShellInterpreter) -> Int32 {
        let target: String
        if let dir = args.first {
            if dir == "-" {
                target = env.getVariable("OLDPWD") ?? ""
            } else if dir.hasPrefix("~") {
                let home = env.getVariable("HOME") ?? ""
                target = home + String(dir.dropFirst())
            } else {
                target = dir
            }
        } else {
            target = env.getVariable("HOME") ?? ""
        }

        guard !target.isEmpty else { return 0 }

        // Save old directory
        let oldPwd = env.getVariable("PWD") ?? ""

        // Pipeline stages and background jobs share the tab's real ios_system
        // session — a chdir there would leak into the foreground shell (and
        // race it). Isolated contexts do a logical cd: PWD variable only.
        if env.isIsolatedContext {
            let resolved = env.resolvePath(target)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir),
                  isDir.boolValue else {
                interp.writeLine("cd: \(target): No such file or directory")
                return 1
            }
            env.setVariable("PWD", value: resolved)
            env.setVariable("OLDPWD", value: oldPwd)
            return 0
        }

        // Use ios_system's chdir
        let sessionPtr = IOSSystemSessionKey.key(for: env.sessionID)
        ios_switchSession(sessionPtr)
        let result = chdir(target)

        if result == 0 {
            // Update PWD and OLDPWD
            if let newDir = ios_getLogicalPWD(sessionPtr) {
                let newPath = newDir as String
                env.setVariable("PWD", value: newPath)
                env.exportVariable("PWD", value: newPath)
            }
            env.setVariable("OLDPWD", value: oldPwd)
            env.exportVariable("OLDPWD", value: oldPwd)
            return 0
        } else {
            interp.writeLine("cd: \(target): No such file or directory")
            return 1
        }
    }

    // MARK: - pwd

    static func builtinPwd(_ args: [String], _ env: ShellEnvironment,
                            _ interp: ShellInterpreter) -> Int32 {
        // Isolated contexts track cwd logically in PWD (see builtinCd)
        if env.isIsolatedContext, let pwd = env.getVariable("PWD") {
            interp.writeLine(pwd)
            return 0
        }
        let sessionPtr = IOSSystemSessionKey.key(for: env.sessionID)
        if let pwd = ios_getLogicalPWD(sessionPtr) {
            interp.writeLine(pwd as String)
        } else if let pwd = env.getVariable("PWD") {
            interp.writeLine(pwd)
        }
        return 0
    }
}

#endif
