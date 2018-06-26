/*
This source file is part of the Swift.org open source project

Copyright 2015 - 2016 Apple Inc. and the Swift project authors
Licensed under Apache License v2.0 with Runtime Library Exception

See http://swift.org/LICENSE.txt for license information
See http://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import Basic
import Build
import Utility
import PackageGraph
import PackageModel

import func POSIX.chdir
import func POSIX.getcwd

/// An enumeration of the errors that can be generated by the run tool.
private enum RunError: Swift.Error {
    /// The package manifest has no executable product.
    case noExecutableFound

    /// Could not find a specific executable in the package manifest.
    case executableNotFound(String)

    /// There are multiple executables and one must be chosen.
    case multipleExecutables([String])
}

extension RunError: CustomStringConvertible {
    var description: String {
        switch self {
        case .noExecutableFound:
            return "no executable product available"
        case .executableNotFound(let executable):
            return "no executable product named '\(executable)'"
        case .multipleExecutables(let executables):
            let joinedExecutables = executables.joined(separator: ", ")
            return "multiple executable products available: \(joinedExecutables)"
        }
    }
}

struct RunFileDeprecatedDiagnostic: DiagnosticData {
    static let id = DiagnosticID(
        type: AnyDiagnostic.self,
        name: "org.swift.diags.run-file-deprecated",
        defaultBehavior: .warning,
        description: {
            $0 <<< "'swift run file.swift' command to interpret swift files is deprecated;"
            $0 <<< "use 'swift file.swift' instead"
        }
    )
}

public class RunToolOptions: ToolOptions {
    /// Returns the mode in with the tool command should run.
    var mode: RunMode {
        // If we got version option, just print the version and exit.
        if shouldPrintVersion {
            return .version
        }

        return .run
    }
    
    /// If the executable product should be built before running.
    var shouldBuild = true
    
    /// The executable product to run.
    var executable: String?
    
    /// The arguments to pass to the executable.
    var arguments: [String] = []
}

public enum RunMode {
    case version
    case run
}

/// swift-run tool namespace
public class SwiftRunTool: SwiftTool<RunToolOptions> {

   public convenience init(args: [String]) {
       self.init(
            toolName: "run",
            usage: "[options] [executable [arguments ...]]",
            overview: "Build and run an executable product",
            args: args,
            seeAlso: type(of: self).otherToolNames()
        )
    }

    override func runImpl() throws {
        switch options.mode {
        case .version:
            print(Versioning.currentVersion.completeDisplayString)

        case .run:
            // Detect deprecated uses of swift run to interpret scripts.
            if let executable = options.executable, isValidSwiftFilePath(executable) {
                print(diagnostic: Diagnostic(
                    location: UnknownLocation.location,
                    data: RunFileDeprecatedDiagnostic()))
                // Redirect execution to the toolchain's swift executable.
                let swiftInterpreterPath = try getToolchain().swiftInterpreter
                // Prepend the script to interpret to the arguments.
                let arguments = [executable] + options.arguments
                try run(swiftInterpreterPath, arguments: arguments)
                return
            }
                    
            let plan = try BuildPlan(buildParameters: self.buildParameters(), graph: loadPackageGraph(), diagnostics: diagnostics)
            let product = try findProduct(in: plan.graph)

            if options.shouldBuild {
                try build(plan: plan, subset: .product(product.name))
            }

            let executablePath = plan.buildParameters.buildPath.appending(component: product.name)
            try run(executablePath, arguments: options.arguments)
        }
    }

    /// Returns the path to the correct executable based on options.
    private func findProduct(in graph: PackageGraph) throws -> ResolvedProduct {
        if let executable = options.executable {
            // If the exectuable is explicitly specified, search through all products.
            guard let executableProduct = graph.allProducts.first(where: {
                $0.type == .executable && $0.name == executable
            }) else {
                throw RunError.executableNotFound(executable)
            }
            
            return executableProduct
        } else {
            // If the executable is implicit, search through root products.
            let rootExecutables = graph.rootPackages.flatMap({ $0.products }).filter({ $0.type == .executable })

            // Error out if the package contains no executables.
            guard rootExecutables.count > 0 else {
                throw RunError.noExecutableFound
            }

            // Only implicitly deduce the executable if it is the only one.
            guard rootExecutables.count == 1 else {
                throw RunError.multipleExecutables(rootExecutables.map({ $0.name }))
            }
            
            return rootExecutables[0]
        }
    }
    
    /// Executes the executable at the specified path.
    private func run(_ excutablePath: AbsolutePath, arguments: [String]) throws {
        // Make sure we are running from the original working directory.
        let cwd: AbsolutePath? = localFileSystem.currentWorkingDirectory
        if cwd == nil || originalWorkingDirectory != cwd {
            try POSIX.chdir(originalWorkingDirectory.asString)
        }

        let pathRelativeToWorkingDirectory = excutablePath.relative(to: originalWorkingDirectory)
        try exec(path: excutablePath.asString, args: [pathRelativeToWorkingDirectory.asString] + arguments)
    }

    /// Determines if a path points to a valid swift file.
    private func isValidSwiftFilePath(_ path: String) -> Bool {
        guard path.hasSuffix(".swift") else { return false }
        //FIXME: Return false when the path is not a valid path string.
        let absolutePath: AbsolutePath
        if path.first == "/" {
            absolutePath = AbsolutePath(path)
        } else {
            guard let cwd = localFileSystem.currentWorkingDirectory else {
                return false
            }
            absolutePath = AbsolutePath(cwd, path)
        }
        return localFileSystem.isFile(absolutePath)
    }

    override class func defineArguments(parser: ArgumentParser, binder: ArgumentBinder<RunToolOptions>) {
        binder.bind(
            option: parser.add(option: "--skip-build", kind: Bool.self,
                usage: "Skip building the executable product"),
            to: { $0.shouldBuild = !$1 })
        
        binder.bindArray(
            positional: parser.add(
                positional: "executable", kind: [String].self, optional: true, strategy: .remaining,
                usage: "The executable to run", completion: .function("_swift_executable")),
            to: {
                $0.executable = $1.first!
                $0.arguments = Array($1.dropFirst())
            })
    }
}

extension SwiftRunTool: ToolName {
    static var toolName: String {
        return "swift run"
    }
}
