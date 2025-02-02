import Foundation

/// An interface for enumerating files that can be linted by SwiftLint.
public protocol LintableFileManager {
    /// Returns all files that can be linted in the specified path. If the path is relative, it will be appended to the
    /// specified root path, or currentt working directory if no root directory is specified.
    ///
    /// - parameter path:          The path in which lintable files should be found.
    /// - parameter rootDirectory: The parent directory for the specified path. If none is provided, the current working
    ///                            directory will be used.
    ///
    /// - returns: Files to lint.
    func filesToLint(inPath path: String, rootDirectory: String?) -> [String]

    /// Returns the date when the file at the specified path was last modified. Returns `nil` if the file cannot be
    /// found or its last modification date cannot be determined.
    ///
    /// - parameter path: The file whose modification date should be determined.
    ///
    /// - returns: A date, if one was determined.
    func modificationDate(forFileAtPath path: String) -> Date?

    /// Returns true if a file (but not a directory) exists at the specified path.
    ///
    /// - parameter path: The path that should be checked to see if it is a file.
    ///
    /// - returns: true if the specified path is a file.
    func isFile(atPath path: String) -> Bool
}

extension FileManager: LintableFileManager {
    public func filesToLint(inPath path: String, rootDirectory: String? = nil) -> [String] {
        let absolutePath = path.bridge()
            .absolutePathRepresentation(rootDirectory: rootDirectory ?? currentDirectoryPath).bridge()
            .standardizingPath

        // if path is a file, it won't be returned by `WalkDir`
        if absolutePath.bridge().isSwiftFile() && absolutePath.isFile {
            return [absolutePath]
        }

        return WalkDir(root: absolutePath).filter {
            $0.hasSuffix(".swift")
        }
    }

    public func modificationDate(forFileAtPath path: String) -> Date? {
        (try? attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    public func isFile(atPath path: String) -> Bool {
        path.isFile
    }
}

/// A very naive recursive search, geared to the needs of `filesToLint`
/// above. Notably
///
/// * much faster than any of the 3 FileManager options (path- and url-based
///   enumerators, subpathsAtPath)
/// * doesn't enter invisible directories (eg. .git)
///
/// Possible shortcomings, if needed for another purpose:
///
/// * does not search invisible directories
/// * only returns regular files (not directories, nor anything weirder)
/// * does not traverse symbolic links
/// * does not limit open directories (theoretical risk of file descriptor exhaustion on
///   extremely deep traversals; extraordinarily unlikely in practice)
///
/// Possible future enhancements, if still too slow:
///
/// * parse and obey `.gitignore` files
/// * include the file extension filter, and avoid constructing the swift string
///   unless `d_name` passes the filter.
private struct WalkDir {
    var root: String
}

extension WalkDir: Sequence {
    struct Iterator: IteratorProtocol {
        var stack: [(path: String, dir: UnsafeMutablePointer<DIR>)]

        mutating func next() -> String? {
            while true {
                guard let (path, dir) = stack.last else {
                    return nil
                }
                guard let entry = readdir(dir) else {
                    self.close()
                    continue
                }

                if entry.pointee.d_name.0 == 0x2e /* . */ {
                    // don't traverse
                    // * the current directory (.)
                    // * the parent directory (..)
                    // * invisible files/directories
                    continue
                }

                func fullPath() -> String {
                    var result = path
                    result.append("/")
                    result.append(entry.filename)
                    return result
                }

                switch Int32(entry.pointee.d_type) {
                case DT_DIR:
                    // don't return directories, but do traverse into them
                    // silently ignore directories we can't traverse
                    _ = self.open(fullPath())
                    continue
                case DT_REG:
                    // return regular files
                    return fullPath()
                case DT_LNK:
                    // don't follow symbolic links
                    continue
                default:
                    // don't return weird things
                    continue
                }
            }
        }

        mutating func open(_ directory: String) -> Bool {
            if let dir = opendir(directory) {
                stack.append((directory, dir))
                return true
            }
            return false
        }

        mutating func close() {
            closedir(stack.popLast()!.dir)
        }

        init(root: String) {
            stack = []
            // silently ignore directories we can't traverse
            _ = open(root)
        }
    }

    func makeIterator() -> Iterator {
        Iterator(root: root)
    }
}

private extension UnsafeMutablePointer where Pointee == dirent {
    var filename: String {
        // Paths should be guaranteed to be UTF-8 on macOS,
        // but are not on Linux. However, the architectural
        // decision to represent paths as Strings runs deep,
        // so non-UTF-8 paths have never worked. This choice
        // of constructor will crash on invalid UTF-8; we
        // could consider a different API for a more graceful
        // failure mode...
        // Alternatively, we could probably choose an even-
        // less-safe constructor which doesn't validate UTF-8?
        withUnsafeBytes(of: &pointee.d_name) { ptr in
            String(cString: ptr.baseAddress!.assumingMemoryBound(to: Int8.self))
        }
    }
}
