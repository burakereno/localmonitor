import Foundation

struct ProjectFailureDiagnosis: Codable, Equatable {
    enum Kind: String, Codable { case node, packageManager, dependencies, environment, port, database, connection, permissions, docker, unknown }
    let kind: Kind
    let title: String
    let recovery: String

    static func classify(logs: [String], exitCode: Int32) -> Self {
        let lines = logs.suffix(100).map { String($0.prefix(2_048)).lowercased() }
        let text = lines.joined(separator: "\n")
        if text.contains("ebadengine") || lines.contains(where: { line in line.contains("node") && ["not supported", "unsupported engine", "requires node"].contains(where: line.contains) }) {
            return Self(kind: .node, title: "Node version is incompatible", recovery: "Check the project's Node declaration and select an installed matching version.")
        }
        if ["eaddrinuse", "address already in use"].contains(where: text.contains) {
            return Self(kind: .port, title: "Port is already in use", recovery: "Inspect the port owner or choose another project port.")
        }
        if ["cannot find module", "err_module_not_found", "module not found", "node_module_version", "err_dlopen_failed", "frozen-lockfile", "outdated_lockfile"].contains(where: text.contains) {
            return Self(kind: .dependencies, title: "Dependencies need attention", recovery: "Run Install Dependencies with the project's selected Node and package manager. Review the lockfile if installation fails.")
        }
        if ["missing env", "database_url is not", "required environment"].contains(where: text.contains)
            || lines.contains(where: { line in line.contains("environment variable")
                && ["missing", "not found", "not set", "required", "undefined", "empty"].contains(where: line.contains) }) {
            return Self(kind: .environment, title: "Environment configuration is incomplete", recovery: "Check the required environment keys and the environment mode in Project Settings.")
        }
        if text.contains("econnrefused") || text.contains("connection refused") {
            let database = ["5432", "6379", "3306", "postgres", "redis", "prisma"].contains(where: text.contains)
            return Self(kind: database ? .database : .connection,
                        title: database ? "Database or cache service is unavailable" : "A dependent service is unavailable",
                        recovery: "Check the dependent service's health endpoint and startup settings before retrying.")
        }
        if text.contains("docker") && ["daemon", "not found", "unhealthy", "cannot connect"].contains(where: text.contains) {
            return Self(kind: .docker, title: "Docker services are unavailable", recovery: "Start Docker and inspect the selected Compose services and their healthchecks.")
        }
        if ["eacces", "permission denied"].contains(where: text.contains) {
            return Self(kind: .permissions, title: "A file or command is not accessible", recovery: "Check project ownership and executable permissions. Avoid running the development server as root.")
        }
        let managerError = ["pnpm: command not found", "yarn: command not found", "npm: command not found", "bun: command not found",
                            "package manager is unavailable", "package manager mismatch", "this project is configured to use"].contains(where: text.contains)
            || lines.contains { line in
                (line.contains("corepack") || line.contains("package manager"))
                    && ["error", "failed", "unavailable", "incompatible", "not found", "mismatch"].contains(where: line.contains)
            }
        if managerError {
            return Self(kind: .packageManager, title: "Package manager is unavailable or incompatible", recovery: "Check package.json's packageManager pin. Use Install Dependencies or install the required tool version.")
        }
        return Self(kind: .unknown, title: "Process exited with code \(exitCode)", recovery: "Open the project logs to inspect the error immediately before exit.")
    }
}

struct ProjectFailureRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    let exitCode: Int32
    let diagnosis: ProjectFailureDiagnosis
}

struct ProjectRestartBudget {
    private(set) var failures: [Date] = []
    mutating func nextDelay(maximum: Int, now: Date = Date()) -> TimeInterval? {
        failures = failures.filter { now.timeIntervalSince($0) < 300 }
        guard failures.count < min(10, max(0, maximum)) else { return nil }
        failures.append(now)
        return min(30, pow(2, Double(failures.count)))
    }
}
